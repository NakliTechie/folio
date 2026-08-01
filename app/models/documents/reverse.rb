# frozen_string_literal: true

module Documents
  # Reverse a posted document with a COMPENSATING document, never a delete (spec §7). A new
  # document with negated lines is posted; the original is marked reversed and linked both ways.
  # The append-only log already forbids deletion; this keeps the document layer honest too.
  module Reverse
    NotReversible = Class.new(StandardError)

    module_function

    def call(document, actor:, on: nil, authorize: nil, capabilities: [])
      ActiveRecord::Base.transaction do
        # Keep the lock order aligned with Documents::Post and Posting.rebuild!: tenant
        # event lock first, document rows second.
        LedgerEvent.acquire_tenant_lock!(document.tenant_id)
        document.lock!
        unless document.reversible?
          raise NotReversible,
            "only a posted, unsettled, not-yet-reversed document can be reversed; reset settlements or use a credit note"
        end
        PurchaseBills::TdsAssessment.assert_no_dependent_bills!(document) if document.doc_type == "PB"

        date = on || document.posting_date || Tenant.find(document.tenant_id).business_date
        entity = Entity.find_by!(tenant_id: document.tenant_id, id: document.entity_id)
        rev = Document.create!(
          tenant_id: document.tenant_id, entity_id: document.entity_id, office_id: document.office_id,
          doc_type: document.doc_type, document_type_id: document.document_type_id,
          fiscal_year: Documents.fiscal_year(date, variant: entity.fiscal_year_variant),
          state: "draft", reverses_document_id: document.id,
          document_date: date, posting_date: date,
          narration: "Reversal of #{document.document_number}",
          party_id: document.party_id, tax_registration_id: document.tax_registration_id,
          purchase_order_id: document.purchase_order_id,
          contract_id: document.contract_id, contract_snapshot: document.contract_snapshot,
          supply_type: document.supply_type,
          place_of_supply_state_code: document.place_of_supply_state_code,
          place_of_supply_evidence: document.place_of_supply_evidence,
          due_date: document.due_date, currency: document.currency,
          minor_unit_exponent: document.minor_unit_exponent,
          subtotal_minor: document.subtotal_minor, tax_minor: document.tax_minor,
          total_minor: document.total_minor, party_snapshot: document.party_snapshot,
          tax_registration_snapshot: document.tax_registration_snapshot,
          tax_breakdown: document.tax_breakdown,
          tds_section: document.tds_section,
          tds_statutory_reference: document.tds_statutory_reference,
          tds_base_basis: document.tds_base_basis,
          tds_trigger_event: document.tds_trigger_event,
          tds_rate_basis_points: document.tds_rate_basis_points,
          tds_taxable_minor: document.tds_taxable_minor,
          tds_prior_taxable_minor: document.tds_prior_taxable_minor,
          tds_prior_deducted_base_minor: document.tds_prior_deducted_base_minor,
          tds_deductible_base_minor: document.tds_deductible_base_minor,
          tds_minor: document.tds_minor
        )
        document.document_lines.each do |dl|
          rev.document_lines.create!(
            tenant_id: document.tenant_id, line_no: dl.line_no, account_code: dl.account_code,
            amount_minor: -dl.amount_minor, currency: dl.currency,
            minor_unit_exponent: dl.minor_unit_exponent, narration: dl.narration,
            extra: ForeignExchange.reverse_extra(dl.extra),
            purchase_order_line_id: dl.purchase_order_line_id,
            item_id: dl.item_id, quantity: dl.quantity, unit_price_minor: dl.unit_price_minor,
            taxable_minor: dl.taxable_minor, hsn_sac_code: dl.hsn_sac_code,
            tax_rate_basis_points: dl.tax_rate_basis_points,
            cess_rate_basis_points: dl.cess_rate_basis_points,
            tax_components: dl.tax_components, item_snapshot: dl.item_snapshot
          )
        end
        entry = Documents::Post.call(
          rev, actor: actor, authorize: authorize, capabilities: capabilities,
          required_capability: "documents.reverse"
        )
        document.update!(state: "reversed", reversed_by_document_id: rev.id)
        clear_original_open_items!(document, reversal_entry: entry, actor: actor, on: date)
        entry
      end
    end

    def clear_original_open_items!(document, reversal_entry:, actor:, on:)
      return unless document.posted_entry_id

      EntryLine.where(entry_id: document.posted_entry_id).open_items.find_each do |item|
        outstanding = Posting::Clearing.open_amount(item)
        original = item.amounts.find_by(slot_role: "transaction")&.amount_minor.to_i.abs
        unless outstanding == original
          raise NotReversible, "a partially settled document requires a credit note, not a reversal"
        end

        Posting::Clearing.clear!(
          item: item, amount_minor: outstanding, cleared_on: on, mode: :full,
          clearing_entry: reversal_entry, actor: actor, reason: "document reversal"
        )
      end
    end
  end
end
