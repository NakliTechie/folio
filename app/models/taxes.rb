# frozen_string_literal: true

module Taxes
  UnsupportedJurisdiction = Class.new(ArgumentError)
  InvalidTaxInput = Class.new(ArgumentError)

  module_function

  def adapter_for!(profile_code)
    profile = Jurisdictions.fetch!(profile_code)
    unless profile.tax_adapter
      raise UnsupportedJurisdiction, "#{profile.name} tax calculation is not available yet"
    end

    profile.tax_adapter.constantize
  end

  def calculate(entity:, **attributes)
    adapter_for!(entity.jurisdiction_profile).calculate(**attributes)
  end
end
