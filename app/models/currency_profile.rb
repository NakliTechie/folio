# frozen_string_literal: true

# The currencies Folio can present faithfully today and their ISO 4217 minor-unit exponents.
# Multi-currency documents need a functional-currency translation slot; until that lands, product
# documents are deliberately fenced to the tenant's one functional currency.
module CurrencyProfile
  UnsupportedCurrency = Class.new(ArgumentError)

  MINOR_UNIT_EXPONENTS = {
    "INR" => 2,
    "EUR" => 2,
    "GBP" => 2,
    "JPY" => 0,
    "KRW" => 0,
    "USD" => 2,
    "MYR" => 2,
    "SGD" => 2,
    "AED" => 2,
    "BHD" => 3,
    "KWD" => 3
  }.freeze

  module_function

  def exponent_for!(currency)
    MINOR_UNIT_EXPONENTS.fetch(currency.to_s.upcase)
  rescue KeyError
    raise UnsupportedCurrency, "currency #{currency.inspect} is not supported"
  end
end
