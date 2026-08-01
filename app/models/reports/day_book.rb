# frozen_string_literal: true

module Reports
  class DayBook
    class << self
      def call(tenant_id:, from_date:, to_date:, entity_id: nil)
        raise ArgumentError, "from date must be on or before the to date" if from_date > to_date

        legal_book = LegalBookScope.call(tenant_id: tenant_id, entity_id: entity_id)
        entry_ids = legal_book.lines.joins(:entry)
          .where(entries: { posting_date: from_date..to_date }).select(:entry_id)
        entries = Entry.where(tenant_id: tenant_id, id: entry_ids)
          .includes(:document, entry_lines: [ :amounts, :ledger ])
          .order(:posting_date, :entered_at, :id)
        rows = entries.map { |entry| row(entry, legal_book.entity) }
        {
          from_date: from_date,
          to_date: to_date,
          entity: entity_hash(legal_book.entity),
          currency: legal_book.currency,
          rows: rows,
          debit_minor: rows.sum { |item| item.fetch(:debit_minor) },
          credit_minor: rows.sum { |item| item.fetch(:credit_minor) }
        }
      end

      private

      def row(entry, entity)
        amounts = entry.entry_lines.select do |line|
          line.entity_id == entity.id && line.posting_layer == "00" &&
            line.line_class == "real" && line.ledger&.posts_to_gl?
        end.map { |line| LegalBookScope.amount_for(line, entity) }
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

      def entity_hash(entity)
        { id: entity.id, code: entity.code, legal_name: entity.legal_name }
      end
    end
  end
end
