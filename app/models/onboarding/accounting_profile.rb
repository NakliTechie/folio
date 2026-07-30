# frozen_string_literal: true

module Onboarding
  # The small, explicit set of accounting identities Folio can provision honestly today.
  # Signup asks for these values rather than silently guessing India/INR/April–March.
  module AccountingProfile
    InvalidChoice = Class.new(ArgumentError)

    JURISDICTIONS = {
      "IN" => "India",
      "DE" => "Germany",
      "UK" => "United Kingdom",
      "US" => "United States",
      "MY" => "Malaysia"
    }.freeze
    CURRENCIES = {
      "INR" => "INR — Indian rupee",
      "EUR" => "EUR — Euro",
      "GBP" => "GBP — Pound sterling",
      "USD" => "USD — US dollar",
      "MYR" => "MYR — Malaysian ringgit"
    }.freeze
    FISCAL_YEARS = {
      "IN_APR_MAR" => "April–March",
      "CAL" => "January–December"
    }.freeze

    DEFAULT_JURISDICTION = "IN"
    DEFAULT_CURRENCY = "INR"
    DEFAULT_FISCAL_YEAR = "IN_APR_MAR"

    Profile = Data.define(:jurisdiction_profile, :functional_currency, :fiscal_year_variant)

    module_function

    def resolve(jurisdiction_profile: nil, functional_currency: nil, fiscal_year_variant: nil)
      values = {
        jurisdiction_profile: jurisdiction_profile.presence || DEFAULT_JURISDICTION,
        functional_currency: functional_currency.presence || DEFAULT_CURRENCY,
        fiscal_year_variant: fiscal_year_variant.presence || DEFAULT_FISCAL_YEAR
      }
      validate_choice!(:jurisdiction_profile, values[:jurisdiction_profile], JURISDICTIONS)
      validate_choice!(:functional_currency, values[:functional_currency], CURRENCIES)
      validate_choice!(:fiscal_year_variant, values[:fiscal_year_variant], FISCAL_YEARS)
      Profile.new(**values)
    end

    def validate_choice!(field, value, choices)
      return if choices.key?(value)

      raise InvalidChoice, "#{field.to_s.humanize} is not supported"
    end
  end
end
