# frozen_string_literal: true

module Posting
  module Rules
    class OpenItemRefund
      class << self
        def lock_dependencies!(document)
          allocation = document.document_allocations.first
          return unless allocation

          EntryLine.where(
            tenant_id: document.tenant_id,
            source_event_id: allocation.target_source_event_id,
            ledger_id: allocation.target_ledger_id,
            line_no: allocation.target_line_no
          ).lock.load
        end

        def validate_document!(document)
          line = document.document_lines.first
          allocation = document.document_allocations.first
          credit = allocation&.target_item
          unless document.doc_type == "RF" && line && document.document_lines.one? &&
                 allocation && document.document_allocations.one? && OpenItemCredits.credit?(credit) &&
                 credit.party_id == document.party_id && allocation.amount_minor == document.total_minor &&
                 allocation.amount_minor.positive? &&
                 allocation.amount_minor <= Posting::Clearing.open_amount(credit)
            raise Documents::InvalidDocument, "refund no longer matches an eligible open credit"
          end
          expected_bank = credit.party_role == "customer" ? -document.total_minor : document.total_minor
          unless line.amount_minor == expected_bank &&
                 OpenItemCredits::BuildRefund::BANK_ACCOUNT_CODES.include?(line.account_code)
            raise Documents::InvalidDocument, "refund cash or bank line was altered"
          end
        end

        def entry_lines(document)
          validate_document!(document)
          allocation = document.document_allocations.first
          credit = allocation.target_item
          bank = document.document_lines.first
          ledger = Ledger.find_by!(tenant_id: document.tenant_id, code: "PRIMARY")
          amount = ->(value) do
            { slot_role: "transaction", currency: document.currency,
              minor_unit_exponent: document.minor_unit_exponent, amount_minor: value }
          end
          [
            { line_no: 1, account_code: bank.account_code, ledger_id: ledger.id,
              entity_id: document.entity_id, office_id: document.office_id,
              amounts: [ amount.call(bank.amount_minor) ] },
            { line_no: 2, account_code: credit.account_code, ledger_id: ledger.id,
              entity_id: document.entity_id, office_id: document.office_id,
              party_id: credit.party_id, party_role: credit.party_role,
              open_item: true, item_class: "normal", assignment: "RF:#{document.id}",
              baseline_date: document.document_date, due_date: document.document_date,
              extra: { "partySnapshot" => document.party_snapshot,
                       "refundedCredit" => allocation.target_snapshot },
              amounts: [ amount.call(-bank.amount_minor) ] }
          ]
        end

        def after_post!(document:, entry:, actor:)
          allocation = document.document_allocations.first
          credit = allocation.target_item
          refund_line = entry.entry_lines.find_by!(line_no: 2)
          reference = { "kind" => "open_item_refund", "documentId" => document.id }
          credit_event = Posting::Clearing.clear!(
            item: credit, amount_minor: allocation.amount_minor, cleared_on: document.document_date,
            mode: allocation.amount_minor == Posting::Clearing.open_amount(credit) ? :full : :partial,
            clearing_entry: entry, actor: actor, reason: "refunded by #{document.document_number}",
            reference: reference
          )
          refund_event = Posting::Clearing.clear!(
            item: refund_line, amount_minor: allocation.amount_minor, cleared_on: document.document_date,
            mode: :full, clearing_entry: entry, actor: actor,
            reason: "refund applied to #{credit.assignment}", reference: reference
          )
          allocation.update_columns(
            target_clearing_event_id: credit_event.id,
            settlement_clearing_event_id: refund_event.id,
            updated_at: Time.current
          )
        end
      end
    end
  end
end
