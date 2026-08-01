# frozen_string_literal: true

module FixedAssets
  module Depreciation
    module_function

    # Straight-line depreciation is calculated as a cumulative daily target and each
    # run posts only the delta to that target. Repeats therefore cannot double-post.
    def cumulative_target(valuation, through_date)
      term = valuation.asset_valuation_term
      start_date = term.depreciation_start_date
      return 0 if through_date < start_date || valuation.gross_block_minor.zero?

      finish = start_date.advance(months: term.useful_life_months) - 1.day
      effective_end = [ through_date, finish ].min
      elapsed_days = (effective_end - start_date).to_i + 1
      total_days = (finish - start_date).to_i + 1
      depreciable = [ valuation.gross_block_minor - term.residual_value_minor, 0 ].max
      (depreciable.to_d * elapsed_days / total_days)
        .round(0, BigDecimal::ROUND_HALF_UP).to_i
    end

    def delta(valuation, through_date)
      [ cumulative_target(valuation, through_date) - valuation.accumulated_depreciation_minor, 0 ].max
    end
  end
end
