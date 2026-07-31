# frozen_string_literal: true

module Documents
  # One finite, bounded decimal boundary for all user-entered document quantities and prices.
  # BigDecimal accepts Infinity and extremely large exponents, so syntax parsing alone is not
  # sufficient before multiplication and rounding.
  module DecimalInput
    MAX_ABSOLUTE = BigDecimal("999999999999.999999")

    module_function

    def parse!(value, label:, scale:, error_class:, minimum: nil, maximum: MAX_ABSOLUTE)
      decimal = begin
        BigDecimal(value.to_s)
      rescue ArgumentError
        raise error_class, "#{label} must be a number"
      end
      unless decimal.finite? && decimal.abs <= maximum
        raise error_class, "#{label} must be finite and no greater than #{maximum.to_s("F")}"
      end
      raise error_class, "#{label} may have no more than #{scale} decimal places" if decimal.scale > scale
      raise error_class, "#{label} must be at least #{minimum}" if minimum && decimal < minimum

      decimal
    end
  end
end
