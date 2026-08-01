# frozen_string_literal: true

require "date"

module Taxes
  module India
    module Tds
      # The effective-dated statutory rate/threshold table and its as-of-date resolver.
      #
      # Statutory reference data lives as a frozen Ruby schedule, following the codebase's
      # precedent for national constants (StateCodes, CurrencyProfile) rather than a
      # per-tenant table — a tenant must not silently edit a statutory rate. A future
      # §197 lower-deduction certificate is a tenant+deductee OVERRIDE that overlays this
      # schedule; it is not built here.
      #
      # A rate change is a NEW ROW with a new window, never an edit — see §194H below, which
      # carries two windows (5% up to 2024-09-30, 2% from 2024-10-01, per the 2024 change).
      # That is what makes "which rate applied on the credit-or-payment date" a pure lookup.
      module Schedule
        # One statutory rate for one (section, deductee category, date window).
        #   deductee_category: :individual_huf | :other | :any  (:any = constitution-independent)
        #   effective_to:      nil = still open
        #   threshold_single_minor: per-transaction threshold below which no TDS (nil = none)
        #   threshold_annual_minor: aggregate threshold below which no TDS (nil = none).
        #              The historical name is retained for compatibility; threshold_period
        #              says whether its accumulation window is a fiscal year or a month.
        #   base_rule: :on_full  → withhold on the whole payment once a threshold is crossed
        #              :on_excess → withhold only on the amount EXCEEDING the annual threshold
        #                           (§194Q — TDS is on purchase value above ₹50L, not the whole).
        #   no_pan_rate_basis_points: a §206AA rate SPECIFIC to this section (nil = the general
        #              "higher of 20% and the section rate" floor). §194Q's no-PAN rate is 5%.
        # Amounts are minor units (paise). Rates are basis points (1% = 100).
        Rate = Data.define(
          :section, :description, :deductee_category,
          :effective_from, :effective_to,
          :rate_basis_points, :threshold_single_minor, :threshold_annual_minor,
          :base_rule, :no_pan_rate_basis_points, :threshold_period
        ) do
          def initialize(base_rule: :on_full, no_pan_rate_basis_points: nil,
                         threshold_period: :fiscal_year, **rest)
            super(
              base_rule: base_rule,
              no_pan_rate_basis_points: no_pan_rate_basis_points,
              threshold_period: threshold_period,
              **rest
            )
          end

          def covers?(date)
            date >= effective_from && (effective_to.nil? || date <= effective_to)
          end

          def open_ended? = effective_to.nil?
          def on_excess? = base_rule == :on_excess
        end

        SECTIONS = {
          "194A"  => "Ordinary interest paid by a non-bank business",
          "194C"  => "Payments to contractors and sub-contractors",
          "194J"  => "Fees for professional or technical services",
          "194H"  => "Commission or brokerage",
          "194I-a" => "Rent of plant, machinery or equipment",
          "194I-b" => "Rent of land, building or furniture",
          "194Q"  => "Purchase of goods above the annual threshold"
        }.freeze

        ACT_2025_EFFECTIVE_FROM = Date.new(2026, 4, 1)
        ACT_2025_REFERENCES = {
          "194A" => "Income-tax Act 2025 §393(1), Table Sl. 5(ii)/(iii)",
          "194H" => "Income-tax Act 2025 §393(1), Table Sl. 1(ii)",
          "194I-a" => "Income-tax Act 2025 §393(1), Table Sl. 2(ii)",
          "194I-b" => "Income-tax Act 2025 §393(1), Table Sl. 2(ii)",
          "194C" => "Income-tax Act 2025 §393(1), Table Sl. 6(i)",
          "194J" => "Income-tax Act 2025 §393(1), Table Sl. 6(iii)",
          "194Q" => "Income-tax Act 2025 §393(1), Table Sl. 8(ii)"
        }.freeze

        # ₹ helper → minor units (paise). Keeps the table readable in rupees.
        RUPEES = ->(r) { r * 100 }

        # Effective windows are sourced from the governing Acts and Finance Act changes. Bahi
        # remains a reconciliation oracle, but stale Bahi thresholds never override statute.
        RATES = [
          # --- 194A ordinary non-bank-business interest: 10%, ₹5k→₹10k FY aggregate ---
          # Bank/co-operative/post-office and senior-citizen categories have different limits;
          # Folio deliberately does not infer those categories from a generic vendor master.
          Rate.new(section: "194A", description: SECTIONS["194A"], deductee_category: :any,
                   effective_from: Date.new(2016, 6, 1), effective_to: Date.new(2025, 3, 31),
                   rate_basis_points: 1_000, threshold_single_minor: nil,
                   threshold_annual_minor: RUPEES.call(5_000)),
          Rate.new(section: "194A", description: SECTIONS["194A"], deductee_category: :any,
                   effective_from: Date.new(2025, 4, 1), effective_to: nil,
                   rate_basis_points: 1_000, threshold_single_minor: nil,
                   threshold_annual_minor: RUPEES.call(10_000)),

          # --- 194C contractors: splits on deductee constitution (1% ind/HUF, 2% others) ---
          Rate.new(section: "194C", description: SECTIONS["194C"], deductee_category: :individual_huf,
                   effective_from: Date.new(2016, 6, 1), effective_to: nil,
                   rate_basis_points: 100, threshold_single_minor: RUPEES.call(30_000),
                   threshold_annual_minor: RUPEES.call(1_00_000)),
          Rate.new(section: "194C", description: SECTIONS["194C"], deductee_category: :other,
                   effective_from: Date.new(2016, 6, 1), effective_to: nil,
                   rate_basis_points: 200, threshold_single_minor: RUPEES.call(30_000),
                   threshold_annual_minor: RUPEES.call(1_00_000)),

          # --- 194J professional services: 10%, constitution-independent ---
          # (The 2% technical-services sub-rate, TDS code 94J-A, is a distinct payment nature
          #  and is deferred; this row is the professional-services case, 94J-B.)
          Rate.new(section: "194J", description: SECTIONS["194J"], deductee_category: :any,
                   effective_from: Date.new(2016, 6, 1), effective_to: Date.new(2025, 3, 31),
                   rate_basis_points: 1_000, threshold_single_minor: nil,
                   threshold_annual_minor: RUPEES.call(30_000)),
          Rate.new(section: "194J", description: SECTIONS["194J"], deductee_category: :any,
                   effective_from: Date.new(2025, 4, 1), effective_to: nil,
                   rate_basis_points: 1_000, threshold_single_minor: nil,
                   threshold_annual_minor: RUPEES.call(50_000)),

          # --- 194H commission/brokerage: the effective-dated showcase ---
          # 5% through 2024-09-30, reduced to 2% from 2024-10-01 (Finance (No. 2) Act 2024).
          Rate.new(section: "194H", description: SECTIONS["194H"], deductee_category: :any,
                   effective_from: Date.new(2016, 6, 1), effective_to: Date.new(2024, 9, 30),
                   rate_basis_points: 500, threshold_single_minor: nil,
                   threshold_annual_minor: RUPEES.call(15_000)),
          Rate.new(section: "194H", description: SECTIONS["194H"], deductee_category: :any,
                   effective_from: Date.new(2024, 10, 1), effective_to: Date.new(2025, 3, 31),
                   rate_basis_points: 200, threshold_single_minor: nil,
                   threshold_annual_minor: RUPEES.call(15_000)),
          Rate.new(section: "194H", description: SECTIONS["194H"], deductee_category: :any,
                   effective_from: Date.new(2025, 4, 1), effective_to: nil,
                   rate_basis_points: 200, threshold_single_minor: nil,
                   threshold_annual_minor: RUPEES.call(20_000)),

          # --- 194I rent: 2% plant/machinery, 10% land/building/furniture ---
          Rate.new(section: "194I-a", description: SECTIONS["194I-a"], deductee_category: :any,
                   effective_from: Date.new(2016, 6, 1), effective_to: Date.new(2025, 3, 31),
                   rate_basis_points: 200, threshold_single_minor: nil,
                   threshold_annual_minor: RUPEES.call(2_40_000)),
          Rate.new(section: "194I-a", description: SECTIONS["194I-a"], deductee_category: :any,
                   effective_from: Date.new(2025, 4, 1), effective_to: nil,
                   rate_basis_points: 200, threshold_single_minor: nil,
                   threshold_annual_minor: RUPEES.call(50_000), threshold_period: :month),
          Rate.new(section: "194I-b", description: SECTIONS["194I-b"], deductee_category: :any,
                   effective_from: Date.new(2016, 6, 1), effective_to: Date.new(2025, 3, 31),
                   rate_basis_points: 1_000, threshold_single_minor: nil,
                   threshold_annual_minor: RUPEES.call(2_40_000)),
          Rate.new(section: "194I-b", description: SECTIONS["194I-b"], deductee_category: :any,
                   effective_from: Date.new(2025, 4, 1), effective_to: nil,
                   rate_basis_points: 1_000, threshold_single_minor: nil,
                   threshold_annual_minor: RUPEES.call(50_000), threshold_period: :month),

          # --- 194Q purchase of goods: 0.1% on value EXCEEDING ₹50L aggregate per seller/FY ---
          # Introduced 2021-07-01. Unlike the others, TDS is on the EXCESS over the threshold
          # (base_rule :on_excess), and the §206AA no-PAN rate is 5% (not the general 20%).
          Rate.new(section: "194Q", description: SECTIONS["194Q"], deductee_category: :any,
                   effective_from: Date.new(2021, 7, 1), effective_to: nil,
                   rate_basis_points: 10, threshold_single_minor: nil,
                   threshold_annual_minor: RUPEES.call(50_00_000),
                   base_rule: :on_excess, no_pan_rate_basis_points: 500)
        ].freeze

        module_function

        def sections = SECTIONS

        def known_section?(section) = SECTIONS.key?(section)

        def statutory_reference(section:, on:)
          raise UnknownSection, "TDS section #{section.inspect} is not in the schedule" unless known_section?(section)
          raise InvalidInput, "on must be a Date" unless on.is_a?(Date)

          if on >= ACT_2025_EFFECTIVE_FROM
            ACT_2025_REFERENCES.fetch(section)
          else
            "Income-tax Act 1961 §#{section}"
          end
        end

        # Resolve the single applicable Rate for a section, deductee category, and date.
        # Prefers an exact category match over an :any row. Raises UnknownSection when no
        # window covers the date (e.g. a payment dated before the section existed here).
        def resolve(section:, deductee_category:, on:)
          unless known_section?(section)
            raise UnknownSection, "TDS section #{section.inspect} is not in the schedule"
          end
          unless DEDUCTEE_CATEGORIES.include?(deductee_category)
            raise InvalidInput, "deductee_category #{deductee_category.inspect} is not recognised"
          end

          candidates = RATES.select do |r|
            r.section == section && r.covers?(on) &&
              (r.deductee_category == deductee_category || r.deductee_category == :any)
          end
          # Exact category beats :any, so a section with a constitution split is resolved
          # to the right leg while an :any section still matches any caller category.
          chosen = candidates.min_by { |r| r.deductee_category == :any ? 1 : 0 }
          unless chosen
            raise UnknownSection,
                  "no TDS rate for section #{section} / #{deductee_category} on #{on}"
          end

          chosen
        end
      end
    end
  end
end
