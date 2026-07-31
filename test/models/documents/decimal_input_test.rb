# frozen_string_literal: true

require "test_helper"

class DocumentsDecimalInputTest < ActiveSupport::TestCase
  Error = Class.new(ArgumentError)

  test "the shared document parser accepts finite bounded decimals" do
    value = Documents::DecimalInput.parse!(
      "123.456789", label: "quantity", scale: 6, error_class: Error
    )
    assert_equal BigDecimal("123.456789"), value
  end

  test "the shared document parser rejects non-finite oversized and over-precise values" do
    %w[Infinity -Infinity NaN 1e1000].each do |input|
      error = assert_raises(Error) do
        Documents::DecimalInput.parse!(input, label: "quantity", scale: 6, error_class: Error)
      end
      assert_match(/finite|no greater/, error.message)
    end

    error = assert_raises(Error) do
      Documents::DecimalInput.parse!("1.0000001", label: "quantity", scale: 6, error_class: Error)
    end
    assert_match(/six|6 decimal places/, error.message)
  end
end
