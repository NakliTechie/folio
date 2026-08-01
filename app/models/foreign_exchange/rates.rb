# frozen_string_literal: true

module ForeignExchange
  module Rates
    module_function

    def create!(tenant:, attributes:, actor:)
      ExchangeRate.transaction do
        rate = ExchangeRate.create!(
          attributes.to_h.symbolize_keys.slice(
            :from_currency, :to_currency, :effective_on, :rate, :rate_type, :source
          ).merge(tenant_id: tenant.id, created_by: actor)
        )
        MasterData::Audit.append!(
          tenant_id: tenant.id, actor: actor, action: "exchange_rate.created",
          ref: "#{rate.from_currency}/#{rate.to_currency}:#{rate.effective_on}",
          subject: {
            "type" => "exchange_rate", "id" => rate.id,
            "fromCurrency" => rate.from_currency, "toCurrency" => rate.to_currency
          },
          changes: {
            "effectiveOn" => { "to" => rate.effective_on.iso8601 },
            "rate" => { "to" => rate.rate.to_s("F") },
            "rateType" => { "to" => rate.rate_type }, "source" => { "to" => rate.source }
          }
        )
        rate
      end
    end
  end
end
