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
    TIME_ZONES = {
      "Asia/Kolkata" => "India — Kolkata",
      "Europe/Berlin" => "Germany — Berlin",
      "Europe/London" => "United Kingdom — London",
      "America/New_York" => "United States — Eastern",
      "America/Chicago" => "United States — Central",
      "America/Denver" => "United States — Mountain",
      "America/Los_Angeles" => "United States — Pacific",
      "Asia/Kuala_Lumpur" => "Malaysia — Kuala Lumpur",
      "UTC" => "UTC"
    }.freeze
    JURISDICTION_TIME_ZONES = {
      "IN" => "Asia/Kolkata", "DE" => "Europe/Berlin", "UK" => "Europe/London",
      "US" => "America/New_York", "MY" => "Asia/Kuala_Lumpur"
    }.freeze

    DEFAULT_JURISDICTION = "IN"
    DEFAULT_CURRENCY = "INR"
    DEFAULT_FISCAL_YEAR = "IN_APR_MAR"

    Profile = Data.define(:jurisdiction_profile, :functional_currency, :fiscal_year_variant, :time_zone)

    module_function

    def resolve(jurisdiction_profile: nil, functional_currency: nil, fiscal_year_variant: nil, time_zone: nil)
      jurisdiction = jurisdiction_profile.presence || DEFAULT_JURISDICTION
      values = {
        jurisdiction_profile: jurisdiction,
        functional_currency: functional_currency.presence || DEFAULT_CURRENCY,
        fiscal_year_variant: fiscal_year_variant.presence || DEFAULT_FISCAL_YEAR,
        time_zone: time_zone.presence || JURISDICTION_TIME_ZONES.fetch(jurisdiction, "UTC")
      }
      validate_choice!(:jurisdiction_profile, values[:jurisdiction_profile], JURISDICTIONS)
      validate_choice!(:functional_currency, values[:functional_currency], CURRENCIES)
      validate_choice!(:fiscal_year_variant, values[:fiscal_year_variant], FISCAL_YEARS)
      validate_choice!(:time_zone, values[:time_zone], TIME_ZONES)
      Profile.new(**values)
    end

    def validate_choice!(field, value, choices)
      return if choices.key?(value)

      raise InvalidChoice, "#{field.to_s.humanize} is not supported"
    end
  end
end
