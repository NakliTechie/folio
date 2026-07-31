# frozen_string_literal: true

module PeriodControls
  module Calendar
    module_function

    def date_range(entity:, fiscal_year:, period_no:)
      fiscal_year = Integer(fiscal_year)
      period_no = Integer(period_no)
      raise InvalidControl, "period must be between 0 and 16" unless (0..16).cover?(period_no)
      return nil if period_no.zero?

      regular_period = [ period_no, 12 ].min
      first = if entity.fiscal_year_variant == "IN_APR_MAR"
        Date.new(fiscal_year, 4, 1).advance(months: regular_period - 1)
      else
        Date.new(fiscal_year, regular_period, 1)
      end
      first..first.end_of_month
    rescue ArgumentError, TypeError
      raise InvalidControl, "fiscal year and period must be valid numbers"
    end

    def label(entity:, fiscal_year:, period_no:)
      range = date_range(entity: entity, fiscal_year: fiscal_year, period_no: period_no)
      return "Period 0 · opening balances" unless range

      suffix = period_no > 12 ? " · special period sharing #{range.first.strftime("%B %Y")}" : ""
      "Period #{period_no} · #{range.first.strftime("%B %Y")}#{suffix}"
    end
  end
end
