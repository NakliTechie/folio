# frozen_string_literal: true

require "test_helper"

# Runs the native synthetic-book generator end to end against the real engine and asserts
# the seeded book is coherent: it ties out, the event chain verifies, the statutory reports
# run, and the frozen TDS assessment matches the shipped kernel. This is the "seeded book is a live
# cross-check" property in test form.
class Folio::SampleBooksTest < ActiveSupport::TestCase
  test "every scenario seeds a fully-posted, tied-out book" do
    Folio::SampleBooks::SCENARIOS.each_key do |code|
      result = Folio::SampleBooks.seed!(scenario: code, email: "sample-books-#{code}@folio.invalid")
      assert result.balanced?, "#{code}: trial balance must tie"
      assert_equal result.trial_balance_debit_minor, result.trial_balance_credit_minor, "#{code}"
      assert result.trial_balance_debit_minor.positive?, "#{code}: a non-empty book should post"

      scenario = Folio::SampleBooks::SCENARIOS.fetch(code)
      assert_equal scenario.sales.size, result.counts[:sales], "#{code}: sales count"
      assert_equal scenario.purchases.size, result.counts[:purchases], "#{code}: purchases count"
    end
  end

  test "the consulting scenario has the expected shape" do
    result = Folio::SampleBooks.seed!(scenario: "consulting", email: "sample-books-shape@folio.invalid")
    assert_equal({ customers: 3, vendors: 2, services: 3, sales: 5, purchases: 2,
                   receipts: 3, payments: 1 }, result.counts)
  end

  test "a seeded book withholds real TDS on vendor credit and yields a non-empty 26Q" do
    result = Folio::SampleBooks.seed!(scenario: "consulting", email: "sb-tds-lifecycle@folio.invalid")
    assert_equal 1, result.tds_deductions_posted, "the 194C subcontractor bill withholds"
    assert result.balanced?, "the book still ties with net AP and TDS payable"

    # BILL1 credited 2026-05-05 → FY2026 Q1; 2% of the GST-exclusive ₹40,000 = ₹800.
    return_26q = Reports.tds_return_26q(result.tenant_id, fiscal_year: 2026, quarter: 1)
    assert_equal 1, return_26q["deduction_count"]
    assert_equal "194C", return_26q["by_section"].first["section"]
    assert_equal 80_000, return_26q["total_tds_minor"]
  end

  test "the goods scenarios exercise the 194Q and 194H TDS sections end to end" do
    manufacturing = Folio::SampleBooks.seed!(scenario: "manufacturing", email: "sb-mfg@folio.invalid")
    q = manufacturing.tds_previews.find { |p| p[:section] == "194Q" }
    assert q, "manufacturing should preview a 194Q goods purchase"
    assert q[:applied], "a GST-exclusive ₹60L purchase exceeds the ₹50L threshold"
    # GST-exclusive ₹60L; excess over ₹50L = ₹10L; 0.1% = ₹1,000.
    assert_equal 100_000, q[:tds_minor]

    pharma = Folio::SampleBooks.seed!(scenario: "pharma", email: "sb-pharma@folio.invalid")
    h = pharma.tds_previews.find { |p| p[:section] == "194H" }
    assert h, "pharma should preview a 194H commission payment"
    assert_equal 200, h[:rate_basis_points], "post-2024 194H rate is 2%"
    assert_equal 80_000, h[:tds_minor], "2% of the GST-exclusive ₹40,000 commission = ₹800"
  end

  test "the seeded book's ledger event chain verifies" do
    result = Folio::SampleBooks.seed!(scenario: "consulting", email: "sample-books-chain@folio.invalid")
    verdict = LedgerEvent.verify_chain(result.tenant_id)
    assert verdict[:ok], "event chain broke at #{verdict[:broken_at]} (#{verdict[:reason]})"
    assert verdict[:rows].positive?
  end

  test "documents get gapless FY-scoped statutory numbers" do
    result = Folio::SampleBooks.seed!(scenario: "consulting", email: "sample-books-numbers@folio.invalid")
    numbers = Document.where(tenant_id: result.tenant_id).where.not(document_number: nil).pluck(:document_number)
    assert_includes numbers, "SI/26-27/00001"
    assert_includes numbers, "PB/26-27/00001"
    assert_includes numbers, "RC/26-27/00001"
    assert_includes numbers, "PY/26-27/00001"
  end

  test "statutory reports run against the seeded book" do
    result = Folio::SampleBooks.seed!(scenario: "consulting", email: "sample-books-reports@folio.invalid")
    tenant_id = result.tenant_id

    day_book = Reports.day_book(tenant_id, from_date: Date.new(2026, 4, 1), to_date: Date.new(2026, 7, 31))
    assert_equal day_book.fetch(:debit_minor), day_book.fetch(:credit_minor), "day book must balance"

    registration = TaxRegistration.find_by!(tenant_id: tenant_id)
    gst = Reports.gst_returns(
      tenant_id, tax_registration_id: registration.id,
      from_date: Date.new(2026, 4, 1), to_date: Date.new(2026, 6, 30)
    )
    assert gst, "GST returns preparation should run"
  end

  test "the TDS preview computes withholding on the tagged subcontractor bill" do
    result = Folio::SampleBooks.seed!(scenario: "consulting", email: "sample-books-tds@folio.invalid")

    preview = result.tds_previews.find { |p| p[:purchase] == "BILL1" }
    assert preview, "BILL1 is a 194C subcontractor bill and should be previewed"
    assert_equal "194C", preview[:section]
    assert preview[:applied], "₹40,000 GST-exclusive base exceeds the ₹30,000 single threshold"
    assert_equal 200, preview[:rate_basis_points]      # firm PAN → 2% leg
    assert_equal 80_000, preview[:tds_minor]           # 2% of ₹40,000 = ₹800 (matches posted withholding)
  end
end
