# frozen_string_literal: true

module OpenItemCredits
  module BuildRefund
    BANK_ACCOUNT_CODES = Settlements::BuildDraft::CASH_ACCOUNT_CODES

    module_function

    def call(tenant:, credit_entry_line_id:, amount_minor:, bank_account_code:, document_date:, narration: nil)
      date = document_date.is_a?(Date) ? document_date : Date.iso8601(document_date.to_s)
      credit = EntryLine.where(tenant_id: tenant.id).includes(:amounts, :party, entry: :document)
        .find(credit_entry_line_id)
      raise InvalidCreditAction, "choose an open customer or vendor credit" unless OpenItemCredits.credit?(credit)

      amount = Integer(amount_minor)
      unless amount.positive? && amount <= Posting::Clearing.open_amount(credit)
        raise InvalidCreditAction, "refund amount exceeds the open credit"
      end
      raise InvalidCreditAction, "refund date cannot precede the credit" if date < credit.entry.posting_date

      bank_code = bank_account_code.to_s.strip
      unless BANK_ACCOUNT_CODES.include?(bank_code) &&
             Account.active.where(tenant_id: tenant.id, code: bank_code, account_type: "asset").exists?
        raise InvalidCreditAction, "choose an active cash or bank account"
      end

      entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      office = Office.find_by!(tenant_id: tenant.id, entity_id: entity.id, code: "PRIMARY")
      type = DocumentType.find_by!(tenant_id: tenant.id, code: "RF", posting_rule: "open_item_refund", active: true)
      currency = tenant.functional_currency
      exponent = CurrencyProfile.exponent_for!(currency)
      party = credit.party
      snapshot = Settlements::BuildDraft.settlement_party_snapshot(party, credit)
      bank_direction = credit.party_role == "customer" ? -1 : 1

      Document.transaction do
        document = Document.create!(
          tenant_id: tenant.id, entity_id: entity.id, office_id: office.id,
          doc_type: "RF", document_type: type,
          fiscal_year: Documents.fiscal_year(date, variant: entity.fiscal_year_variant),
          document_date: date, posting_date: date, due_date: date,
          narration: narration.presence || "Refund open #{credit.party_role} credit",
          state: "draft", party: party, currency: currency, minor_unit_exponent: exponent,
          subtotal_minor: amount, tax_minor: 0, total_minor: amount, party_snapshot: snapshot
        )
        document.document_lines.create!(
          tenant_id: tenant.id, line_no: 1, account_code: bank_code,
          amount_minor: bank_direction * amount, currency: currency,
          minor_unit_exponent: exponent, narration: document.narration,
          extra: { "refundRole" => credit.party_role }
        )
        document.document_allocations.create!(
          tenant_id: tenant.id, line_no: 1, target_entry_line_id: credit.id,
          target_source_event_id: credit.source_event_id, target_ledger_id: credit.ledger_id,
          target_line_no: credit.line_no, amount_minor: amount, clearing_mode: "partial",
          target_snapshot: Settlements::BuildDraft.target_snapshot(credit)
        )
        Posting::Rules::OpenItemRefund.validate_document!(document)
        document
      end
    rescue InvalidCreditAction
      raise
    rescue Date::Error, ArgumentError, TypeError
      raise InvalidCreditAction, "refund date or amount is invalid"
    rescue ActiveRecord::RecordNotFound
      raise InvalidCreditAction, "refund master or open credit is unavailable"
    end
  end
end
