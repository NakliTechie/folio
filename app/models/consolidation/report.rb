# frozen_string_literal: true

module Consolidation
  module Report
    module_function

    def trial_balance(group:, as_of:)
      date = as_of.is_a?(Date) ? as_of : Date.iso8601(as_of.to_s)
      members = group.consolidation_group_members.select { |member| member.effective_from <= date }
      member_ids = members.map(&:entity_id)
      members_by_entity = members.index_by(&:entity_id)
      accounts = Account.where(tenant_id: group.tenant_id).index_by(&:code)
      totals = Hash.new { |hash, code| hash[code] = { base: 0, eliminations: 0, entities: Hash.new(0) } }
      EntryLine.includes(:amounts).joins(:entry).where(
        tenant_id: group.tenant_id, entity_id: member_ids, line_class: "real",
        posting_layer: %w[00 EL], ledger_id: Ledger.where(tenant_id: group.tenant_id, posts_to_gl: true)
      ).where("entries.posting_date <= ?", date).find_each do |line|
        next unless members_by_entity.fetch(line.entity_id).effective_on?(line.entry.posting_date)

        amount = reporting_amount(line, group.presentation_currency)
        next if amount.nil?
        bucket = totals[line.account_code]
        if line.posting_layer == "EL"
          bucket[:eliminations] += amount
        else
          bucket[:base] += amount
          bucket[:entities][line.entity_id] += amount
        end
      end
      rows = totals.filter_map do |code, values|
        consolidated = values.fetch(:base) + values.fetch(:eliminations)
        next if values.fetch(:base).zero? && values.fetch(:eliminations).zero?
        account = accounts[code]
        {
          account_code: code, account_name: account&.name || code,
          account_type: account&.account_type, base_minor: values.fetch(:base),
          eliminations_minor: values.fetch(:eliminations), consolidated_minor: consolidated,
          entity_amounts: values.fetch(:entities)
        }
      end
      {
        group: group, as_of: date, presentation_currency: group.presentation_currency,
        entities: Entity.where(tenant_id: group.tenant_id, id: member_ids).order(:code).to_a,
        rows: rows.sort_by { |row| account_sort_key(row.fetch(:account_code)) }
      }
    rescue Date::Error
      raise InvalidConsolidation, "reporting date must be a valid ISO date"
    end

    def reporting_amount(line, currency)
      functional = line.amounts.find do |amount|
        amount.slot_role == "functional" && amount.currency == currency
      end
      transaction = line.amounts.find do |amount|
        amount.slot_role == "transaction" && amount.currency == currency
      end
      (functional || transaction)&.amount_minor
    end

    def account_sort_key(code)
      code.match?(/\A\d+\z/) ? [ 0, code.to_i ] : [ 1, code ]
    end
  end
end
