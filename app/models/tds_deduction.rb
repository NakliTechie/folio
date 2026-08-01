# frozen_string_literal: true

# One recorded tax-deducted-at-source event on a vendor payment. Frozen, derived evidence
# for the Form 26Q return and Form 16A certificate — see CreateTdsDeductions for why it holds
# soft references and frozen snapshots rather than hard foreign keys.
class TdsDeduction < ApplicationRecord
  self.table_name = "tds_deductions"

  validates :tenant_id, :party_id, :section, :rate_basis_points, :taxable_minor, :tds_minor,
            :deduction_date, :deductee_name_snapshot, :source_document_id, :fiscal_year, :quarter,
            presence: true
  validates :section, inclusion: { in: ->(_) { Taxes::India::Tds::Schedule::SECTIONS.keys } }
  validates :rate_basis_points, :taxable_minor, :tds_minor,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :quarter, inclusion: { in: 1..4 }

  scope :for_tenant, ->(tenant_id) { where(tenant_id: tenant_id) }
  scope :in_period, ->(fiscal_year, quarter) { where(fiscal_year: fiscal_year, quarter: quarter) }

  # India TDS return quarter for a date: Q1 Apr–Jun, Q2 Jul–Sep, Q3 Oct–Dec, Q4 Jan–Mar.
  # (Documents.fiscal_year already gives the Apr–Mar fiscal year; this is its quarter sibling.)
  def self.india_quarter(date)
    case date.month
    when 4..6 then 1
    when 7..9 then 2
    when 10..12 then 3
    else 4
    end
  end
end
