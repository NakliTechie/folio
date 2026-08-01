# frozen_string_literal: true

require "test_helper"
require "securerandom"

class TdsDeductionTest < ActiveSupport::TestCase
  def valid_attrs(overrides = {})
    {
      tenant_id: 1, party_id: 1, section: "194C", rate_basis_points: 200,
      taxable_minor: 4_000_000, tds_minor: 80_000, deduction_date: Date.new(2026, 6, 17),
      deductee_name_snapshot: "Precision Job Works", source_document_id: 1,
      fiscal_year: 2026, quarter: 1
    }.merge(overrides)
  end

  test "a well-formed deduction is valid" do
    assert TdsDeduction.new(valid_attrs).valid?
  end

  test "section must be a known schedule section" do
    refute TdsDeduction.new(valid_attrs(section: "194Z")).valid?
    assert TdsDeduction.new(valid_attrs(section: "194Q")).valid?
  end

  test "amounts must be non-negative integers and quarter within 1..4" do
    refute TdsDeduction.new(valid_attrs(tds_minor: -1)).valid?
    refute TdsDeduction.new(valid_attrs(quarter: 5)).valid?
    refute TdsDeduction.new(valid_attrs(quarter: 0)).valid?
  end

  test "name snapshot and source document are required" do
    refute TdsDeduction.new(valid_attrs(deductee_name_snapshot: nil)).valid?
    refute TdsDeduction.new(valid_attrs(source_document_id: nil)).valid?
  end

  test "india_quarter maps months to the Apr-Mar TDS quarters" do
    assert_equal 1, TdsDeduction.india_quarter(Date.new(2026, 4, 1))
    assert_equal 2, TdsDeduction.india_quarter(Date.new(2026, 8, 15))
    assert_equal 3, TdsDeduction.india_quarter(Date.new(2026, 11, 30))
    assert_equal 4, TdsDeduction.india_quarter(Date.new(2027, 1, 15))
    assert_equal 4, TdsDeduction.india_quarter(Date.new(2027, 3, 31))
  end

  test "the database rejects an out-of-range quarter" do
    err = assert_raises(ActiveRecord::StatementInvalid) do
      TdsDeduction.connection.execute(<<~SQL)
        INSERT INTO tds_deductions
          (tenant_id, party_id, section, rate_basis_points, taxable_minor, tds_minor,
           deduction_date, deductee_name_snapshot, source_document_id, fiscal_year, quarter,
           created_at, updated_at)
        VALUES (1, 1, '194C', 200, 100, 2, '2026-06-17', 'X', 1, 2026, 9, now(), now())
      SQL
    end
    assert_match(/tds_deductions_quarter_valid/, err.message)
  end
end
