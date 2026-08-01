# frozen_string_literal: true

module Controlling
  module Dimensions
    module_function

    def snapshot(cost_center, on:)
      date = on.is_a?(Date) ? on : Date.iso8601(on.to_s)
      raise InvalidControl, "cost center is not effective on #{date}" unless cost_center.effective_on?(date)

      profit = cost_center.profit_center
      segment = profit.controlling_segment
      {
        "costCenterId" => cost_center.id, "costCenterCode" => cost_center.code,
        "profitCenterId" => profit.id, "profitCenterCode" => profit.code,
        "segmentId" => segment.id, "segmentCode" => segment.code,
        "effectiveOn" => date.to_s
      }
    rescue Date::Error
      raise InvalidControl, "dimension date must be a valid ISO date"
    end

    def validate_snapshot!(tenant, data, on:)
      values = data.to_h.deep_stringify_keys
      center = CostCenter.includes(profit_center: :controlling_segment)
        .where(tenant_id: tenant.id).find(values.fetch("costCenterId"))
      expected = snapshot(center, on: on)
      raise InvalidControl, "controlling dimension snapshot does not match governed master data" unless
        expected == values

      expected
    rescue KeyError, ActiveRecord::RecordNotFound
      raise InvalidControl, "choose a valid cost center in this company"
    end

    def line_fields(cost_center, on:)
      data = snapshot(cost_center, on: on)
      {
        cost_object_type: "cost_center", cost_object_id: data.fetch("costCenterId"),
        profit_center_id: data.fetch("profitCenterId"), segment_id: data.fetch("segmentId"),
        extra: { "controlling" => data }
      }
    end
  end
end
