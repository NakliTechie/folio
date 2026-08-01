# frozen_string_literal: true

module Reports
  class PartyLedger
    def self.call(tenant_id:, party_id:, entity_id: nil)
      party = Party.where(tenant_id: tenant_id).find(party_id)
      legal_book = LegalBookScope.call(
        tenant_id: tenant_id, entity_id: entity_id, include_statistical: true
      )
      lines = EntryLine.includes(:amounts, entry: :document)
        .where(id: legal_book.lines.select(:id), party_id: party.id)
        .joins(:entry)
        .order("entries.posting_date", "entries.id", :line_no)

      running = 0
      rows = lines.filter_map do |line|
        ledger_amount = line.line_class == "real" ? LegalBookScope.amount_for(line, legal_book.entity) : 0
        running += ledger_amount
        {
          entry_line_id: line.id,
          posting_date: line.entry.posting_date,
          document_id: line.entry.document_id,
          document_number: line.entry.document&.document_number,
          assignment: line.assignment,
          party_role: line.party_role,
          debit_minor: [ ledger_amount, 0 ].max,
          credit_minor: [ -ledger_amount, 0 ].max,
          running_balance_minor: running,
          open_item: line.open_item?,
          outstanding_minor: line.open_item? && line.cleared_on.nil? ?
            LegalBookScope.functional_open_amount(line, legal_book.entity) : 0,
          cleared_on: line.cleared_on
        }
      end

      {
        party: {
          id: party.id, party_number: party.party_number, name: party.name,
          roles: party.role_codes
        },
        entity: {
          id: legal_book.entity.id, code: legal_book.entity.code,
          legal_name: legal_book.entity.legal_name
        },
        currency: legal_book.currency,
        rows: rows,
        balance_minor: running,
        open_minor: rows.sum { |row| row[:outstanding_minor] }
      }
    end
  end
end
