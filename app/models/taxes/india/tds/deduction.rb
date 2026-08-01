# frozen_string_literal: true

require "date"

module Taxes
  module India
    module Tds
      # The pure TDS deduction calculator — a PORO with no persistence (only ActiveSupport
      # niceties like String#present?), so the standard can be tested against it directly,
      # mirroring the GST Adapter's shape (Taxes::India::Adapter).
      #
      # Given a payment under a section on a date, decides whether tax must be withheld and
      # how much, applying three statutory rules:
      #   1. Effective-dated rate — resolved from Schedule as of the payment date.
      #   2. Threshold — a single-payment threshold and/or an FY-aggregate threshold; the
      #      caller passes how much has already been paid to this deductee under this section
      #      this financial year (fy_paid_to_date_minor) so the aggregate rule can fire.
      #   3. §206AA — a deductee without a valid PAN is deducted at the higher of the section
      #      rate and 20%.
      #
      # Rounding matches the GST adapter exactly: round-half-up on non-negative minor units,
      # denominator 10_000 (basis points). One rounding rule across the whole tax surface.
      #
      # DEFERRED (lifecycle, not here): once the FY-aggregate threshold is crossed, statute
      # expects catch-up withholding on earlier sub-threshold payments too. This calculator
      # withholds on the CURRENT payment and reports `annual_threshold_crossed` so the
      # lifecycle layer can compute catch-up; it does not reach back into prior payments.
      # Statutory rupee-rounding of the challan (§288B) is also a return-time concern.
      module Deduction
        Result = Data.define(
          :section, :applied, :reason, :rate_basis_points,
          :taxable_minor, :tds_minor, :net_minor,
          :pan_available, :deductee_category,
          :single_threshold_crossed, :annual_threshold_crossed
        )

        module_function

        # `pan` is the deductee's PAN string (or nil). `deductee_category` may be given
        # explicitly; otherwise it is derived from the PAN, defaulting to :other (the
        # higher-rate leg) when it cannot be — a conservative default that §206AA makes
        # moot for the amount anyway.
        def compute(section:, on:, amount_minor:, pan: nil, deductee_category: nil,
                    fy_paid_to_date_minor: 0)
          amount = non_negative_integer!(amount_minor, "amount_minor")
          prior  = non_negative_integer!(fy_paid_to_date_minor, "fy_paid_to_date_minor")
          raise InvalidInput, "on must be a Date" unless on.is_a?(Date)

          pan_available = pan.present? && Taxes::India::Pan.valid?(pan)
          category = deductee_category || Taxes::India::Pan.deductee_category(pan) || :other

          rate = Schedule.resolve(section: section, deductee_category: category, on: on)

          # STRICTLY greater-than: the Act says "where the [amount / aggregate] does not
          # exceed X, no deduction shall be made" (e.g. §194C(5)). So a payment or aggregate
          # EXACTLY equal to the threshold attracts NO TDS; only crossing it does. `>=` here
          # would over-withhold by one rupee at the boundary.
          single_crossed = rate.threshold_single_minor && amount > rate.threshold_single_minor
          annual_crossed = rate.threshold_annual_minor &&
                           (prior + amount) > rate.threshold_annual_minor
          no_threshold = rate.threshold_single_minor.nil? && rate.threshold_annual_minor.nil?

          applied = single_crossed || annual_crossed || no_threshold
          reason =
            if !applied then :below_threshold
            elsif no_threshold then :no_threshold
            elsif single_crossed then :single_threshold
            else :annual_threshold
            end

          effective_rate = if pan_available
            rate.rate_basis_points
          else
            [ rate.rate_basis_points, NO_PAN_FLOOR_BASIS_POINTS ].max
          end

          tds = applied ? round_half_up(amount, effective_rate) : 0

          Result.new(
            section: section,
            applied: applied,
            reason: reason,
            rate_basis_points: applied ? effective_rate : 0,
            taxable_minor: amount,
            tds_minor: tds,
            net_minor: amount - tds,
            pan_available: pan_available,
            deductee_category: category,
            single_threshold_crossed: !!single_crossed,
            annual_threshold_crossed: !!annual_crossed
          )
        end

        # Round-half-up minor-unit application of a basis-point rate. Identical to
        # Taxes::India::Adapter#tax_amount so TDS and GST never round differently.
        def round_half_up(base_minor, rate_basis_points)
          ((base_minor * rate_basis_points) + 5_000) / 10_000
        end

        def non_negative_integer!(value, label)
          unless value.is_a?(Integer) && value >= 0
            raise InvalidInput, "#{label} must be a non-negative integer minor amount"
          end

          value
        end
      end
    end
  end
end
