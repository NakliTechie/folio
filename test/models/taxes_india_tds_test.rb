# frozen_string_literal: true

require "test_helper"
require "date"

# The TDS correctness kernel: PAN structure, effective-dated rate resolution, and the pure
# deduction calculator (thresholds, §206AA, rounding). Style mirrors TaxesIndiaTest.
class TaxesIndiaTdsTest < ActiveSupport::TestCase
  Pan       = Taxes::India::Pan
  Schedule  = Taxes::India::Tds::Schedule
  Deduction = Taxes::India::Tds::Deduction
  Base      = Taxes::India::Tds::Base

  # ₹ → minor units (paise), so the test reads in rupees.
  def rs(rupees) = rupees * 100

  test "invoice credit excludes separately stated GST while a pre-invoice advance uses gross" do
    invoice = Base.for_invoice(
      gross_minor: rs(1_18_000), gst_minor: rs(18_000), gst_separately_stated: true
    )
    advance = Base.for_advance_payment(gross_minor: rs(1_18_000))

    assert_equal rs(1_00_000), invoice.taxable_minor
    assert_equal "invoice_excluding_separately_stated_gst", invoice.basis
    assert_equal "credit", invoice.trigger_event
    assert_equal rs(1_18_000), advance.taxable_minor
    assert_equal "advance_payment_gross_before_invoice", advance.basis
    assert_equal "advance_payment", advance.trigger_event
  end

  # --- PAN structure and holder-type routing ---

  test "PAN validation checks the AAAAA9999A structure" do
    assert Pan.valid?("ABCPD1234E")
    assert Pan.valid?("abcpd1234e") # normalised upcase
    refute Pan.valid?("ABC1234E")
    refute Pan.valid?("ABCPD1234")
    refute Pan.valid?("1BCPD1234E")
    refute Pan.valid?("")
  end

  test "PAN holder type comes from the fourth character" do
    assert_equal :individual, Pan.holder_type("ABCPD1234E") # P
    assert_equal :company,    Pan.holder_type("ABCCD1234E") # C
    assert_equal :huf,        Pan.holder_type("ABCHD1234E") # H
    assert_nil Pan.holder_type("not-a-pan")
  end

  test "deductee category collapses to the individual/HUF vs other split" do
    assert_equal :individual_huf, Pan.deductee_category("ABCPD1234E")
    assert_equal :individual_huf, Pan.deductee_category("ABCHD1234E")
    assert_equal :other,          Pan.deductee_category("ABCCD1234E")
    assert_equal :other,          Pan.deductee_category("ABCFD1234E") # firm
    assert_nil Pan.deductee_category(nil)
    assert_nil Pan.deductee_category("garbage")
  end

  # --- effective-dated resolution ---

  test "194H resolves to 5% before the 2024-10-01 cut and 2% on/after it" do
    before = Schedule.resolve(section: "194H", deductee_category: :any, on: Date.new(2024, 9, 30))
    on_cut = Schedule.resolve(section: "194H", deductee_category: :any, on: Date.new(2024, 10, 1))
    later  = Schedule.resolve(section: "194H", deductee_category: :any, on: Date.new(2026, 4, 1))

    assert_equal 500, before.rate_basis_points
    assert_equal 200, on_cut.rate_basis_points
    assert_equal 200, later.rate_basis_points
  end

  test "resolving a section before its first window is an UnknownSection" do
    assert_raises(Taxes::India::Tds::UnknownSection) do
      Schedule.resolve(section: "194H", deductee_category: :any, on: Date.new(2016, 1, 1))
    end
  end

  test "an unlisted section raises" do
    assert_raises(Taxes::India::Tds::UnknownSection) do
      Schedule.resolve(section: "194Z", deductee_category: :any, on: Date.new(2025, 6, 1))
    end
  end

  test "194C resolves the right leg for the deductee constitution" do
    ind = Schedule.resolve(section: "194C", deductee_category: :individual_huf, on: Date.new(2025, 6, 1))
    oth = Schedule.resolve(section: "194C", deductee_category: :other, on: Date.new(2025, 6, 1))
    assert_equal 100, ind.rate_basis_points
    assert_equal 200, oth.rate_basis_points
  end

  test "Finance Act 2025 thresholds and the monthly rent period resolve by date" do
    old_j = Schedule.resolve(section: "194J", deductee_category: :any, on: Date.new(2025, 3, 31))
    new_j = Schedule.resolve(section: "194J", deductee_category: :any, on: Date.new(2025, 4, 1))
    new_h = Schedule.resolve(section: "194H", deductee_category: :any, on: Date.new(2025, 4, 1))
    rent = Schedule.resolve(section: "194I-b", deductee_category: :any, on: Date.new(2025, 4, 1))

    assert_equal rs(30_000), old_j.threshold_annual_minor
    assert_equal rs(50_000), new_j.threshold_annual_minor
    assert_equal rs(20_000), new_h.threshold_annual_minor
    assert_equal rs(50_000), rent.threshold_annual_minor
    assert_equal :month, rent.threshold_period
  end

  test "statutory references switch to section 393 on 1 April 2026" do
    assert_equal "Income-tax Act 1961 §194C",
      Schedule.statutory_reference(section: "194C", on: Date.new(2026, 3, 31))
    assert_equal "Income-tax Act 2025 §393(1), Table Sl. 6(i)",
      Schedule.statutory_reference(section: "194C", on: Date.new(2026, 4, 1))
  end

  # --- deduction: thresholds ---

  test "194J withholds 10% once the annual threshold is crossed" do
    r = Deduction.compute(section: "194J", on: Date.new(2025, 6, 1),
                          amount_minor: rs(60_000), pan: "ABCCD1234E")
    assert r.applied
    assert_equal :annual_threshold, r.reason
    assert_equal 1_000, r.rate_basis_points
    assert_equal rs(6_000), r.tds_minor
    assert_equal rs(54_000), r.net_minor
  end

  test "a payment below the annual threshold withholds nothing" do
    r = Deduction.compute(section: "194J", on: Date.new(2025, 6, 1),
                          amount_minor: rs(20_000), pan: "ABCCD1234E")
    refute r.applied
    assert_equal :below_threshold, r.reason
    assert_equal 0, r.tds_minor
    assert_equal rs(20_000), r.net_minor
  end

  test "the annual aggregate rule fires on a sub-threshold payment once prior payments cross it" do
    r = Deduction.compute(section: "194J", on: Date.new(2025, 6, 1),
                          amount_minor: rs(40_000), pan: "ABCCD1234E",
                          period_taxable_to_date_minor: rs(15_000),
                          prior_deducted_base_minor: 0)
    assert r.applied, "prior 15k + this 40k = 55k crosses the current 50k annual threshold"
    assert r.annual_threshold_crossed
    assert_equal rs(55_000), r.deductible_base_minor
    assert_equal rs(5_500), r.tds_minor
  end

  test "aggregate catch-up subtracts the base already deducted" do
    r = Deduction.compute(
      section: "194C", on: Date.new(2026, 6, 1), amount_minor: rs(20_000),
      pan: "ABCCD1234E", period_taxable_to_date_minor: rs(90_000),
      prior_deducted_base_minor: rs(40_000)
    )

    assert_equal rs(70_000), r.deductible_base_minor
    assert_equal rs(1_400), r.tds_minor
  end

  test "an amount exactly equal to the threshold does not withhold (the Act says 'exceeds')" do
    # §194C: ₹30,000 single threshold. Exactly ₹30,000 must NOT be deducted; ₹30,001 must.
    at = Deduction.compute(section: "194C", on: Date.new(2025, 6, 1),
                           amount_minor: rs(30_000), pan: "ABCPD1234E")
    over = Deduction.compute(section: "194C", on: Date.new(2025, 6, 1),
                             amount_minor: rs(30_000) + 1, pan: "ABCPD1234E")
    refute at.applied, "exactly at the threshold attracts no TDS"
    assert_equal 0, at.tds_minor
    assert over.applied, "one paisa over the threshold attracts TDS"
  end

  test "an aggregate exactly equal to the annual threshold does not withhold" do
    # Current 194J annual ₹50,000. prior ₹10,000 + this ₹40,000 = exactly ₹50,000.
    at = Deduction.compute(section: "194J", on: Date.new(2025, 6, 1),
                           amount_minor: rs(40_000), pan: "ABCCD1234E",
                           fy_paid_to_date_minor: rs(10_000))
    refute at.applied
    assert_equal 0, at.tds_minor
  end

  test "194C uses the single-payment threshold and the deductee's constitution rate" do
    ind = Deduction.compute(section: "194C", on: Date.new(2025, 6, 1),
                           amount_minor: rs(40_000), pan: "ABCPD1234E") # individual → 1%
    oth = Deduction.compute(section: "194C", on: Date.new(2025, 6, 1),
                           amount_minor: rs(40_000), pan: "ABCCD1234E") # company → 2%

    assert_equal :single_threshold, ind.reason
    assert_equal 100, ind.rate_basis_points
    assert_equal rs(400), ind.tds_minor
    assert_equal 200, oth.rate_basis_points
    assert_equal rs(800), oth.tds_minor
  end

  # --- deduction: §206AA (no PAN) ---

  test "a deductee without a valid PAN is withheld at the higher 20% floor" do
    r = Deduction.compute(section: "194C", on: Date.new(2025, 6, 1),
                          amount_minor: rs(40_000), pan: nil)
    assert r.applied
    refute r.pan_available
    assert_equal 2_000, r.rate_basis_points  # max(section 2%, 20% floor) = 20%
    assert_equal rs(8_000), r.tds_minor       # 20% of 40,000
  end

  test "an invalid PAN string is treated as no PAN for §206AA" do
    r = Deduction.compute(section: "194J", on: Date.new(2025, 6, 1),
                          amount_minor: rs(50_000), pan: "NOTVALID")
    refute r.pan_available
    assert_equal 2_000, r.rate_basis_points
  end

  # --- deduction: effective-dated rate flows through to the amount ---

  test "the same 194H commission withholds differently either side of the rate cut" do
    args = { section: "194H", amount_minor: rs(20_000), pan: "ABCCD1234E" }
    before = Deduction.compute(on: Date.new(2024, 9, 30), **args)
    after  = Deduction.compute(on: Date.new(2024, 10, 1), **args)

    assert_equal rs(1_000), before.tds_minor  # 5%
    assert_equal rs(400),   after.tds_minor    # 2%
  end

  # --- rounding: half-up, and identical to the GST adapter ---

  test "the rate application rounds half up" do
    # 10% of 12,345 minor = 1,234.5 → 1,235; of 12,344 = 1,234.4 → 1,234.
    assert_equal 1_235, Deduction.round_half_up(12_345, 1_000)
    assert_equal 1_234, Deduction.round_half_up(12_344, 1_000)
  end

  test "TDS rounding matches the GST adapter exactly" do
    [ [ 12_345, 1_000 ], [ 999_999, 200 ], [ 4_000_000, 100 ], [ 7_777, 500 ] ].each do |base, bps|
      assert_equal Taxes::India::Adapter.tax_amount(base, bps),
                   Deduction.round_half_up(base, bps),
                   "TDS and GST must round #{base}@#{bps}bps identically"
    end
  end

  # --- 194A interest (added from the Bahi reconciliation) ---

  test "194A withholds 10% on interest once the annual threshold is crossed" do
    r = Deduction.compute(section: "194A", on: Date.new(2025, 6, 1),
                          amount_minor: rs(50_000), pan: "ABCCD1234E")
    assert r.applied
    assert_equal 1_000, r.rate_basis_points
    assert_equal rs(5_000), r.tds_minor          # 10% of ₹50,000
    assert_equal rs(50_000), r.deductible_base_minor
  end

  # --- 194Q purchase of goods: excess-over-threshold base + 5% no-PAN (added, reconciled) ---

  test "194Q withholds 0.1% only on the value EXCEEDING the ₹50L annual threshold" do
    # prior ₹48L + this ₹5L = ₹53L aggregate → ₹3L over the ₹50L threshold.
    r = Deduction.compute(section: "194Q", on: Date.new(2025, 6, 1),
                          amount_minor: rs(5_00_000), pan: "ABCCD1234E",
                          fy_paid_to_date_minor: rs(48_00_000))
    assert r.applied
    assert_equal 10, r.rate_basis_points                 # 0.1%
    assert_equal rs(3_00_000), r.deductible_base_minor    # only the ₹3L excess
    assert_equal rs(300), r.tds_minor                     # 0.1% of ₹3L = ₹300
  end

  test "194Q withholds on the whole payment once the aggregate is already over the threshold" do
    r = Deduction.compute(section: "194Q", on: Date.new(2025, 6, 1),
                          amount_minor: rs(5_00_000), pan: "ABCCD1234E",
                          period_taxable_to_date_minor: rs(60_00_000),
                          prior_deducted_base_minor: rs(10_00_000))
    assert_equal rs(5_00_000), r.deductible_base_minor    # whole payment is excess
    assert_equal rs(500), r.tds_minor                     # 0.1% of ₹5L
  end

  test "194Q withholds nothing while the aggregate stays under ₹50L" do
    r = Deduction.compute(section: "194Q", on: Date.new(2025, 6, 1),
                          amount_minor: rs(5_00_000), pan: "ABCCD1234E",
                          fy_paid_to_date_minor: rs(40_00_000))
    refute r.applied
    assert_equal 0, r.deductible_base_minor
    assert_equal 0, r.tds_minor
  end

  test "194Q uses its special 5% no-PAN rate, not the general 20% floor" do
    r = Deduction.compute(section: "194Q", on: Date.new(2025, 6, 1),
                          amount_minor: rs(5_00_000), pan: nil,
                          fy_paid_to_date_minor: rs(48_00_000))
    refute r.pan_available
    assert_equal 500, r.rate_basis_points                 # §206AA for 194Q = 5%, not 2000 bps
    assert_equal rs(15_000), r.tds_minor                  # 5% of the ₹3L excess
  end

  test "194Q did not exist before 2021-07-01" do
    assert_raises(Taxes::India::Tds::UnknownSection) do
      Deduction.compute(section: "194Q", on: Date.new(2021, 6, 30),
                        amount_minor: rs(60_00_000), pan: "ABCCD1234E")
    end
  end

  # --- input guards ---

  test "a negative amount is rejected" do
    assert_raises(Taxes::India::Tds::InvalidInput) do
      Deduction.compute(section: "194J", on: Date.new(2025, 6, 1), amount_minor: -1, pan: "ABCCD1234E")
    end
  end

  test "a non-Date payment date is rejected" do
    assert_raises(Taxes::India::Tds::InvalidInput) do
      Deduction.compute(section: "194J", on: "2025-06-01", amount_minor: rs(50_000), pan: "ABCCD1234E")
    end
  end
end
