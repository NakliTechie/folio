# frozen_string_literal: true

module Taxes
  module India
    # Ordinary domestic GST routing for the services-first vertical. SEZ, export, reverse-charge,
    # composition, and place-of-supply exceptions are rejected by later document rules until they
    # have explicit models; this calculator never guesses them.
    module Adapter
      Result = Data.define(:nature, :taxable_minor, :rate_basis_points, :components, :total_tax_minor)

      module_function

      def calculate(taxable_minor:, rate_basis_points:, supplier_state_code:, place_of_supply_state_code:,
                    cess_rate_basis_points: 0)
        taxable = integer_in_range!(taxable_minor, "taxable_minor", 0..)
        rate = integer_in_range!(rate_basis_points, "rate_basis_points", 0..4000)
        cess_rate = integer_in_range!(cess_rate_basis_points, "cess_rate_basis_points", 0..10_000)
        supplier_state = state_code!(supplier_state_code, "supplier_state_code")
        place_state = state_code!(place_of_supply_state_code, "place_of_supply_state_code")

        nature = supplier_state == place_state ? :intra_state : :inter_state
        components = if nature == :inter_state
          { igst: tax_amount(taxable, rate) }
        else
          state_component = StateCodes.union_territory_without_legislature?(supplier_state) ? :utgst : :sgst
          { cgst: tax_amount(taxable, rate, divisor: 2),
            state_component => tax_amount(taxable, rate, divisor: 2) }
        end
        components[:cess] = tax_amount(taxable, cess_rate) if cess_rate.positive?

        Result.new(
          nature: nature,
          taxable_minor: taxable,
          rate_basis_points: rate,
          components: components.freeze,
          total_tax_minor: components.values.sum
        )
      end

      def tax_amount(taxable_minor, rate_basis_points, divisor: 1)
        denominator = 10_000 * divisor
        ((taxable_minor * rate_basis_points) + (denominator / 2)) / denominator
      end

      def integer_in_range!(value, label, range)
        unless value.is_a?(Integer) && range.cover?(value)
          raise InvalidTaxInput, "#{label} is outside the supported range"
        end

        value
      end

      def state_code!(value, label)
        code = value.to_s
        raise InvalidTaxInput, "#{label} is not a valid GST state code" unless StateCodes.valid?(code)

        code
      end
    end
  end
end
