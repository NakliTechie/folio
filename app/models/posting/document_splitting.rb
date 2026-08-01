# frozen_string_literal: true

module Posting
  # Adds technical zero-balance lines whenever a posting crosses governed management
  # dimensions. The clearing account nets to zero for the entry, but each dimension slice
  # independently balances for every ledger/currency slot.
  module DocumentSplitting
    CLEARING_ACCOUNT_CODE = "2990"

    module_function

    def apply(lines, clearing_account_code: CLEARING_ACCOUNT_CODE)
      normalized = lines.map(&:dup)
      return normalized unless normalized.any? { |line| dimensioned?(line) }

      original_offenders = PostEntry.balance_offenders(normalized)
      raise UnbalancedError, original_offenders unless original_offenders.empty?

      next_line = normalized.map { |line| Integer(line.fetch(:line_no)) }.max + 1
      split_lines = dimension_offenders(normalized).filter_map do |key, amounts|
        nonzero = amounts.reject { |_slot, amount| amount.zero? }
        next if nonzero.empty?

        ledger_id, entity_id, office_id, profit_center_id, segment_id, posting_layer = key
        source_lines = normalized.select do |line|
          dimension_key(line) == key && line[:split_kind].nil?
        end.map { |line| line.fetch(:line_no) }
        {
          line_no: next_line.tap { next_line += 1 }, account_code: clearing_account_code,
          ledger_id: ledger_id, entity_id: entity_id, office_id: office_id,
          profit_center_id: profit_center_id, segment_id: segment_id,
          line_class: "real", posting_layer: posting_layer,
          split_kind: "zero_balance",
          extra: { "documentSplitting" => {
            "kind" => "zero_balance", "sourceLineNumbers" => source_lines.sort
          } },
          amounts: nonzero.map do |(slot_role, currency, exponent), amount|
            {
              slot_role: slot_role, currency: currency,
              minor_unit_exponent: exponent, amount_minor: -amount
            }
          end
        }
      end
      result = normalized + split_lines
      offenders = PostEntry.balance_offenders(result)
      raise UnbalancedError, offenders unless offenders.empty?
      raise UnbalancedError, per_dimension_offenders(result) if per_dimension_offenders(result).any?

      result
    end

    def per_dimension_offenders(lines)
      dimension_offenders(lines).each_with_object({}) do |(key, amounts), result|
        amounts.each do |(slot_role, currency, _exponent), amount|
          result[[ *key, slot_role, currency ]] = amount unless amount.zero?
        end
      end
    end

    def dimension_offenders(lines)
      lines.each_with_object(Hash.new { |hash, key| hash[key] = Hash.new(0) }) do |line, result|
        line.fetch(:amounts).each do |amount|
          amount_key = [
            amount.fetch(:slot_role), amount.fetch(:currency),
            Integer(amount.fetch(:minor_unit_exponent))
          ]
          result[dimension_key(line)][amount_key] += Integer(amount.fetch(:amount_minor))
        end
      end
    end

    def dimension_key(line)
      [
        line.fetch(:ledger_id), line.fetch(:entity_id), line.fetch(:office_id),
        line[:profit_center_id], line[:segment_id], line[:posting_layer] || "00"
      ]
    end

    def dimensioned?(line)
      line[:profit_center_id].present? || line[:segment_id].present?
    end
  end
end
