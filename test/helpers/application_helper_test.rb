# frozen_string_literal: true

require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "money formatting remains exact beyond the binary Float integer range" do
    assert_equal "INR 90,071,992,547,409.93", money_amount(9_007_199_254_740_993)
    assert_equal "INR -1.23", money_amount(-123)
  end

  test "money formatting uses the currency profile exponent" do
    original = CurrencyProfile.method(:exponent_for!)
    CurrencyProfile.define_singleton_method(:exponent_for!) { |currency| currency == "JPY" ? 0 : original.call(currency) }
    assert_equal "JPY 82,000", money_amount(82_000, currency: "JPY")
  ensure
    CurrencyProfile.define_singleton_method(:exponent_for!, original) if original
  end
end
