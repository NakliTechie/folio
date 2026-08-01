# frozen_string_literal: true

module Reports
  class OpenItems
    CONFIG = {
      "customer" => { account_code: "1200", direction: 1 },
      "vendor" => { account_code: "2000", direction: -1 }
    }.freeze
    BUCKETS = %w[current days_1_30 days_31_60 days_61_90 days_91_plus].freeze

    def self.call(tenant_id:, role:, aged_to:, entity_id: nil)
      config = CONFIG.fetch(role.to_s) { raise ArgumentError, "role must be customer or vendor" }
      date = aged_to.to_date
      legal_book = LegalBookScope.call(
        tenant_id: tenant_id, entity_id: entity_id, include_statistical: true
      )
      lines = EntryLine.open_items.includes(:party, :amounts, entry: :document)
        .where(
          id: legal_book.lines.select(:id),
          account_code: config.fetch(:account_code),
          party_role: role
        )
        .where("baseline_date <= ?", date)
        .references(:entries).where("entries.posting_date <= ?", date)
        .order(:party_id, :due_date, :baseline_date, :id)

      rows = lines.filter_map do |line|
        transaction_amount = line.amounts.find { |amount| amount.slot_role == "transaction" }&.amount_minor.to_i
        outstanding = LegalBookScope.functional_open_amount(line, legal_book.entity)
        next unless outstanding.positive?

        normal = transaction_amount * config.fetch(:direction) > 0

        age_days = (date - line.baseline_date).to_i
        {
          entry_line_id: line.id,
          party_id: line.party_id,
          party_number: line.party&.party_number,
          party_name: line.party&.name || "Party ##{line.party_id}",
          source_document_id: line.entry.document_id,
          source_document_number: line.entry.document&.document_number,
          assignment: line.assignment,
          posting_date: line.entry.posting_date,
          baseline_date: line.baseline_date,
          due_date: line.due_date,
          age_days: age_days,
          bucket: bucket_for(age_days),
          outstanding_minor: outstanding,
          position: normal ? (role.to_s == "customer" ? "receivable" : "payable") : "credit",
          signed_outstanding_minor: normal ? outstanding : -outstanding
        }
      end
      charges, credits = rows.partition { |row| row[:position] != "credit" }
      totals = BUCKETS.to_h do |bucket|
        [ bucket, charges.sum { |row| row[:bucket] == bucket ? row[:outstanding_minor] : 0 } ]
      end

      {
        role: role.to_s,
        aged_to: date,
        basis: "current_open_items",
        entity: {
          id: legal_book.entity.id, code: legal_book.entity.code,
          legal_name: legal_book.entity.legal_name
        },
        currency: legal_book.currency,
        rows: charges,
        credits: credits,
        totals: totals,
        total_minor: charges.sum { |row| row[:outstanding_minor] },
        credit_total_minor: credits.sum { |row| row[:outstanding_minor] },
        net_total_minor: rows.sum { |row| row[:signed_outstanding_minor] }
      }
    end

    def self.bucket_for(age_days)
      return "current" if age_days <= 0
      return "days_1_30" if age_days <= 30
      return "days_31_60" if age_days <= 60
      return "days_61_90" if age_days <= 90

      "days_91_plus"
    end
  end
end
