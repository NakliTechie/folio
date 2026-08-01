# frozen_string_literal: true

module ForeignExchange
  MissingRate = Class.new(ArgumentError)
  Translation = Data.define(
    :amount_minor, :rate, :rate_date, :rate_source, :rate_basis, :exchange_rate
  )

  module_function

  def translate(tenant_id:, amount_minor:, from_currency:, to_currency:, on:, rate_type: "spot")
    source = from_currency.to_s.upcase
    target = to_currency.to_s.upcase
    if source == target
      return Translation.new(amount_minor, BigDecimal("1"), on, "identity", "posting_date", nil)
    end

    rate, reciprocal = resolve_rate(
      tenant_id: tenant_id, from_currency: source, to_currency: target,
      on: on, rate_type: rate_type
    )
    applied_rate = reciprocal ? BigDecimal("1") / rate.rate : rate.rate
    source_exponent = CurrencyProfile.exponent_for!(source)
    target_exponent = CurrencyProfile.exponent_for!(target)
    major = BigDecimal(amount_minor.to_s) / (10**source_exponent)
    translated = (major * applied_rate * (10**target_exponent)).round(0, BigDecimal::ROUND_HALF_EVEN).to_i
    provenance = reciprocal ? "#{rate.source} (reciprocal)" : rate.source
    Translation.new(translated, applied_rate, rate.effective_on, provenance, "posting_date", rate)
  end

  def resolve_rate(tenant_id:, from_currency:, to_currency:, on:, rate_type:)
    scope = ExchangeRate.where(tenant_id: tenant_id, rate_type: rate_type)
    direct = scope.where(from_currency: from_currency, to_currency: to_currency)
      .where(effective_on: ..on).order(effective_on: :desc).first
    return [ direct, false ] if direct

    inverse = scope.where(from_currency: to_currency, to_currency: from_currency)
      .where(effective_on: ..on).order(effective_on: :desc).first
    return [ inverse, true ] if inverse

    raise MissingRate,
      "no #{rate_type} rate from #{from_currency} to #{to_currency} is available on or before #{on}"
  end

  def snapshot(translation, functional_currency:)
    {
      "functionalCurrency" => functional_currency,
      "functionalAmountMinor" => translation.amount_minor,
      "rate" => translation.rate.to_s("F"),
      "rateDate" => translation.rate_date.iso8601,
      "rateSource" => translation.rate_source,
      "rateBasis" => translation.rate_basis,
      "exchangeRateId" => translation.exchange_rate&.id
    }.compact
  end

  def translated_minor(amount_minor:, from_currency:, to_currency:, rate:)
    source_exponent = CurrencyProfile.exponent_for!(from_currency)
    target_exponent = CurrencyProfile.exponent_for!(to_currency)
    major = BigDecimal(amount_minor.to_s) / (10**source_exponent)
    (major * BigDecimal(rate.to_s) * (10**target_exponent))
      .round(0, BigDecimal::ROUND_HALF_EVEN).to_i
  end

  def validate_snapshot!(tenant:, line:)
    expected_exponent = CurrencyProfile.exponent_for!(line.currency)
    unless line.minor_unit_exponent == expected_exponent
      raise Documents::InvalidDocument,
        "#{line.account_code} must use #{line.currency} minor-unit exponent #{expected_exponent}"
    end
    return if line.currency == tenant.functional_currency

    snapshot = line.extra.to_h.fetch("currencyTranslation", nil)
    unless snapshot.is_a?(Hash) && snapshot["functionalCurrency"] == tenant.functional_currency
      raise Documents::InvalidDocument, "#{line.account_code} is missing its frozen functional-currency translation"
    end
    expected = translated_minor(
      amount_minor: line.amount_minor, from_currency: line.currency,
      to_currency: tenant.functional_currency, rate: snapshot.fetch("rate")
    )
    unless snapshot["functionalAmountMinor"].to_i == expected &&
        snapshot.values_at("rateDate", "rateSource", "rateBasis").all?(&:present?)
      raise Documents::InvalidDocument, "#{line.account_code} functional-currency translation was altered"
    end
  rescue KeyError, ArgumentError
    raise Documents::InvalidDocument, "#{line.account_code} functional-currency translation is incomplete"
  end

  def reverse_extra(extra)
    snapshot = extra.to_h.deep_dup
    translation = snapshot["currencyTranslation"]
    if translation
      translation["functionalAmountMinor"] = -Integer(translation.fetch("functionalAmountMinor"))
    end
    snapshot
  end
end
