# frozen_string_literal: true

# One explicit registry resolves country-specific policy. Posting rules ask the profile for an
# adapter; the posting core never branches on a country code.
module Jurisdictions
  UnsupportedProfile = Class.new(ArgumentError)
  Profile = Data.define(
    :code, :name, :currency, :fiscal_year_variant, :registration_kinds, :tax_adapter
  )

  PROFILES = {
    "IN" => Profile.new(
      code: "IN", name: "India", currency: "INR", fiscal_year_variant: "IN_APR_MAR",
      registration_kinds: %w[GSTIN TAN ISD], tax_adapter: "Taxes::India::Adapter"
    ),
    "DE" => Profile.new(
      code: "DE", name: "Germany", currency: "EUR", fiscal_year_variant: "CAL",
      registration_kinds: %w[VAT], tax_adapter: nil
    ),
    "UK" => Profile.new(
      code: "UK", name: "United Kingdom", currency: "GBP", fiscal_year_variant: "CAL",
      registration_kinds: %w[VAT], tax_adapter: nil
    ),
    "US" => Profile.new(
      code: "US", name: "United States", currency: "USD", fiscal_year_variant: "CAL",
      registration_kinds: %w[EIN], tax_adapter: nil
    ),
    "MY" => Profile.new(
      code: "MY", name: "Malaysia", currency: "MYR", fiscal_year_variant: "CAL",
      registration_kinds: %w[SST], tax_adapter: nil
    )
  }.freeze

  module_function

  def fetch!(code)
    PROFILES.fetch(code.to_s.upcase)
  rescue KeyError
    raise UnsupportedProfile, "jurisdiction profile #{code.inspect} is not supported"
  end
end
