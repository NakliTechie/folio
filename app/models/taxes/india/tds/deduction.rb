# frozen_string_literal: true

require "date"

module Taxes
  module India
    module Tds
      # The pure TDS deduction calculator — a PORO with no persistence (only ActiveSupport
      # niceties like String#present?), so the standard can be tested against it directly,
      # mirroring the GST Adapter's shape (Taxes::India::Adapter).
      #
      # Given a credit/payment amount under a section on a date, decides whether tax must be withheld and
      # how much, applying three statutory rules:
      #   1. Effective-dated rate — resolved from Schedule as of the payment date.
      #   2. Threshold — a single-payment threshold and/or an FY-aggregate threshold; the
      #      caller passes prior taxable and already-deducted bases for the rate's accumulation
      #      period (FY for most sections, calendar month for rent from 2025-04-01).
      #   3. §206AA — a deductee without a valid PAN is deducted at the higher of the section
      #      rate and 20%, unless the section sets its own no-PAN rate (§194Q → 5%).
      #
      # Rounding matches the GST adapter exactly: round-half-up on non-negative minor units,
      # denominator 10_000 (basis points). One rounding rule across the whole tax surface.
      #
      # When an aggregate threshold is first crossed, deductible_base_minor includes the
      # previously assessed but not-yet-deducted base. This makes catch-up deterministic and
      # idempotent: the caller supplies prior_deducted_base_minor, not merely prior TDS tax.
      # Statutory rupee-rounding of the challan remains a return-time concern.
      module Deduction
        Result = Data.define(
          :section, :applied, :reason, :rate_basis_points,
          :taxable_minor, :deductible_base_minor, :tds_minor, :net_minor,
          :pan_available, :deductee_category,
          :single_threshold_crossed, :annual_threshold_crossed,
          :threshold_period, :statutory_reference
        )

        module_function

        # `pan` is the deductee's PAN string (or nil). `deductee_category` may be given
        # explicitly; otherwise it is derived from the PAN, defaulting to :other (the
        # higher-rate leg) when it cannot be — a conservative default that §206AA makes
        # moot for the amount anyway.
        def compute(section:, on:, amount_minor:, pan: nil, deductee_category: nil,
                    period_taxable_to_date_minor: nil, prior_deducted_base_minor: 0,
                    fy_paid_to_date_minor: nil)
          amount = non_negative_integer!(amount_minor, "amount_minor")
          if period_taxable_to_date_minor && fy_paid_to_date_minor
            raise InvalidInput,
              "pass period_taxable_to_date_minor or fy_paid_to_date_minor, not both"
          end
          prior_value = period_taxable_to_date_minor || fy_paid_to_date_minor || 0
          prior = non_negative_integer!(prior_value, "period_taxable_to_date_minor")
          prior_deducted = non_negative_integer!(
            prior_deducted_base_minor, "prior_deducted_base_minor"
          )
          raise InvalidInput, "on must be a Date" unless on.is_a?(Date)

          pan_available = pan.present? && Taxes::India::Pan.valid?(pan)
          category = deductee_category || Taxes::India::Pan.deductee_category(pan) || :other

          rate = Schedule.resolve(section: section, deductee_category: category, on: on)

          # STRICTLY greater-than: the Act says "where the [amount / aggregate] does not
          # exceed X, no deduction shall be made" (e.g. §194C(5)). So a payment or aggregate
          # EXACTLY equal to the threshold attracts NO TDS; only crossing it does. `>=` here
          # would over-withhold by one rupee at the boundary.
          single_crossed = rate.threshold_single_minor && amount > rate.threshold_single_minor
          aggregate_crossed = rate.threshold_annual_minor &&
                           (prior + amount) > rate.threshold_annual_minor
          no_threshold = rate.threshold_single_minor.nil? && rate.threshold_annual_minor.nil?

          applied = single_crossed || aggregate_crossed || no_threshold
          reason =
            if !applied then :below_threshold
            elsif no_threshold then :no_threshold
            elsif single_crossed then :single_threshold
            elsif rate.threshold_period == :month then :monthly_threshold
            else :annual_threshold
            end

          # §206AA: without a valid PAN, withhold at the section's own no-PAN rate if it has
          # one (§194Q → 5%), else the general "higher of 20% and the section rate" floor.
          effective_rate = if pan_available
            rate.rate_basis_points
          elsif rate.no_pan_rate_basis_points
            rate.no_pan_rate_basis_points
          else
            [ rate.rate_basis_points, NO_PAN_FLOOR_BASIS_POINTS ].max
          end

          # For an aggregate threshold, target the total statutory base reached to date and
          # subtract the base already deducted. That captures catch-up exactly once. A
          # single-transaction threshold that fires before the aggregate threshold applies
          # only to the current amount.
          deductible_base =
            if !applied
              0
            elsif aggregate_crossed
              target_base = if rate.on_excess?
                (prior + amount) - rate.threshold_annual_minor
              else
                prior + amount
              end
              [ target_base - prior_deducted, 0 ].max
            else
              amount
            end

          tds = round_half_up(deductible_base, effective_rate)

          Result.new(
            section: section,
            applied: applied,
            reason: reason,
            rate_basis_points: effective_rate,
            taxable_minor: amount,
            deductible_base_minor: deductible_base,
            tds_minor: tds,
            net_minor: amount - tds,
            pan_available: pan_available,
            deductee_category: category,
            single_threshold_crossed: !!single_crossed,
            annual_threshold_crossed: !!aggregate_crossed,
            threshold_period: rate.threshold_period,
            statutory_reference: Schedule.statutory_reference(section: section, on: on)
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
