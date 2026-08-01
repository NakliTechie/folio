# frozen_string_literal: true

require "test_helper"

# Runs the native synthetic-book generator end to end against the real engine and asserts
# the seeded book is coherent: it ties out, the event chain verifies, the statutory reports
# run, and the TDS preview matches the shipped kernel. This is the "seeded book is a live
# cross-check" property in test form.
class Folio::SampleBooksTest < ActiveSupport::TestCase
  test "the consulting scenario seeds a fully-posted, tied-out book" do
    result = Folio::SampleBooks.seed!(scenario: "consulting", email: "sample-books-test@folio.invalid")

    # Masters + documents all created and posted.
    assert_equal({ customers: 3, vendors: 2, services: 3, sales: 5, purchases: 2,
                   receipts: 3, payments: 1 }, result.counts)

    # Double entry holds across the whole book.
    assert result.balanced?, "trial balance must tie"
    assert_equal result.trial_balance_debit_minor, result.trial_balance_credit_minor
    assert result.trial_balance_debit_minor.positive?, "a non-empty book should have postings"
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
    assert preview[:applied], "₹40,000 exceeds the ₹30,000 single threshold"
    assert_equal 200, preview[:rate_basis_points]      # firm PAN → 2% leg
    assert_equal 80_000, preview[:tds_minor]            # 2% of ₹40,000 = ₹800
  end
end
