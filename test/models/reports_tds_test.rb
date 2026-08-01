# frozen_string_literal: true

require "test_helper"

# Form 26Q (return) + Form 16A (certificate) over tds_deductions (7L.4, 7L.5).
class ReportsTdsTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "tds-reports@folio.invalid", password: "correct-horse-battery-staple",
      org_name: "TDS Reports Co"
    )
    @tenant_id = @org.tenant.id
    deduct(party: 101, section: "194C", taxable: 4_720_000, tds: 94_400, date: Date.new(2026, 8, 20),
           pan: "AABFN3456J", name: "Nilgiri Subcontractors")
    deduct(party: 101, section: "194J", taxable: 5_000_000, tds: 500_000, date: Date.new(2026, 9, 10),
           pan: "AABFN3456J", name: "Nilgiri Subcontractors")
    deduct(party: 202, section: "194H", taxable: 2_000_000, tds: 40_000, date: Date.new(2026, 7, 15),
           pan: "AABCK5678G", name: "Kaveri Brokers")
    # A Q1 deduction that must be EXCLUDED from a Q2 report.
    deduct(party: 101, section: "194C", taxable: 3_000_000, tds: 60_000, date: Date.new(2026, 5, 1),
           pan: "AABFN3456J", name: "Nilgiri Subcontractors")
  end

  def deduct(party:, section:, taxable:, tds:, date:, pan:, name:)
    TdsDeduction.create!(
      tenant_id: @tenant_id, party_id: party, section: section, rate_basis_points: 200,
      statutory_reference: Taxes::India::Tds::Schedule.statutory_reference(section: section, on: date),
      gross_minor: taxable, gst_minor: 0, taxable_minor: taxable,
      deductible_base_minor: taxable, tds_minor: tds,
      base_basis: "legacy_payment_gross", trigger_event: "payment", kind: "deduction",
      deduction_date: date, deductee_pan: pan,
      deductee_name_snapshot: name, source_document_id: TdsDeduction.count + 1,
      entry_id: 1,
      fiscal_year: 2026, quarter: TdsDeduction.india_quarter(date)
    )
  end

  test "26Q aggregates a quarter by section and by deductee, excluding other quarters" do
    r = Reports.tds_return_26q(@tenant_id, fiscal_year: 2026, quarter: 2)

    assert_equal "26Q", r["form"]
    assert_equal 3, r["deduction_count"], "Q2 only — the Q1 row is excluded"
    assert_equal 94_400 + 500_000 + 40_000, r["total_tds_minor"]

    assert_equal %w[194C 194H 194J], r["by_section"].map { |s| s["section"] }
    assert_equal 2, r["deductees"].size
    nilgiri = r["deductees"].find { |d| d["party_id"] == 101 }
    assert_equal 2, nilgiri["count"]
    assert_equal 94_400 + 500_000, nilgiri["tds_minor"]
    assert_equal 2, nilgiri["deductions"].size
  end

  test "16A is a single deductee's certificate with the deductor's name and the correct form number" do
    r = Reports.tds_certificate_16a(@tenant_id, party_id: 101, fiscal_year: 2026, quarter: 2)

    assert_equal "16A", r["form"], "the TDS certificate is 16A, not Bahi's 27D"
    assert_equal "TDS Reports Co", r["deductor"]["name"]
    assert_equal "Nilgiri Subcontractors", r["deductee"]["name"]
    assert_equal "AABFN3456J", r["deductee"]["pan"]
    assert_equal 2, r["deductions"].size
    assert_equal 94_400 + 500_000, r["total_tds_minor"]
  end

  test "an empty period yields a zeroed return, not an error" do
    r = Reports.tds_return_26q(@tenant_id, fiscal_year: 2025, quarter: 1)
    assert_equal 0, r["deduction_count"]
    assert_equal 0, r["total_tds_minor"]
    assert_empty r["deductees"]
  end
end
