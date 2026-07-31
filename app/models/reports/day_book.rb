# frozen_string_literal: true

module Reports
  class DayBook
    class << self
      def call(tenant_id:, from_date:, to_date:)
        raise ArgumentError, "from date must be on or before the to date" if from_date > to_date

        entries = Entry.where(tenant_id: tenant_id, posting_date: from_date..to_date)
          .includes(:document, entry_lines: :amounts)
          .order(:posting_date, :entered_at, :id)
        rows = entries.map { |entry| row(entry) }
        {
          from_date: from_date,
          to_date: to_date,
          rows: rows,
          debit_minor: rows.sum { |item| item.fetch(:debit_minor) },
          credit_minor: rows.sum { |item| item.fetch(:credit_minor) }
        }
      end

      private

      def row(entry)
        amounts = entry.entry_lines.flat_map(&:amounts)
          .select { |amount| amount.slot_role == "transaction" }
          .map(&:amount_minor)
        document = entry.document
        {
          entry_id: entry.id,
          posting_date: entry.posting_date,
          document_date: entry.document_date,
          document_type: document&.doc_type,
          document_number: document&.document_number,
          narration: document&.narration,
          party_name: document&.party_snapshot&.fetch("name", nil),
          debit_minor: amounts.select(&:positive?).sum,
          credit_minor: -amounts.select(&:negative?).sum
        }
      end
    end
  end
end
