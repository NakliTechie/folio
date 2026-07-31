# frozen_string_literal: true

module Reports
  class PartyLedger
    def self.call(tenant_id:, party_id:)
      party = Party.where(tenant_id: tenant_id).find(party_id)
      lines = EntryLine.includes(:amounts, entry: :document)
        .where(tenant_id: tenant_id, party_id: party.id)
        .joins(:entry)
        .order("entries.posting_date", "entries.id", :line_no)

      running = 0
      rows = lines.filter_map do |line|
        amount = line.amounts.find { |candidate| candidate.slot_role == "transaction" }
        next unless amount

        running += amount.amount_minor
        {
          entry_line_id: line.id,
          posting_date: line.entry.posting_date,
          document_id: line.entry.document_id,
          document_number: line.entry.document&.document_number,
          assignment: line.assignment,
          party_role: line.party_role,
          debit_minor: [ amount.amount_minor, 0 ].max,
          credit_minor: [ -amount.amount_minor, 0 ].max,
          running_balance_minor: running,
          open_item: line.open_item?,
          outstanding_minor: line.open_item? && line.cleared_on.nil? ? Posting::Clearing.open_amount(line) : 0,
          cleared_on: line.cleared_on
        }
      end

      {
        party: {
          id: party.id, party_number: party.party_number, name: party.name,
          roles: party.role_codes
        },
        rows: rows,
        balance_minor: running,
        open_minor: rows.sum { |row| row[:outstanding_minor] }
      }
    end
  end
end
