# frozen_string_literal: true

# One recorded tax-deducted-at-source event on a vendor credit (or its explicit reversal).
# Immutable, event-replayable evidence
# for the Form 26Q return and Form 16A certificate — see CreateTdsDeductions for why it holds
# soft references and frozen snapshots rather than hard foreign keys.
class TdsDeduction < ApplicationRecord
  self.table_name = "tds_deductions"

  KINDS = %w[deduction reversal].freeze
  BASES = %w[
    invoice_excluding_separately_stated_gst
    invoice_gross_gst_not_separately_stated
    advance_payment_gross_before_invoice
    legacy_payment_gross
  ].freeze
  TRIGGERS = %w[credit advance_payment payment].freeze

  validates :tenant_id, :party_id, :section, :statutory_reference, :rate_basis_points,
            :gross_minor, :gst_minor, :taxable_minor, :deductible_base_minor, :tds_minor,
            :base_basis, :trigger_event, :kind,
            :deduction_date, :deductee_name_snapshot, :source_document_id, :fiscal_year, :quarter,
            presence: true
  validates :section, inclusion: { in: ->(_) { Taxes::India::Tds::Schedule::SECTIONS.keys } }
  validates :kind, inclusion: { in: KINDS }
  validates :base_basis, inclusion: { in: BASES }
  validates :trigger_event, inclusion: { in: TRIGGERS }
  validates :rate_basis_points, :gross_minor, :gst_minor, :taxable_minor, :deductible_base_minor,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :tds_minor, numericality: { only_integer: true, greater_than: 0 }
  validates :quarter, inclusion: { in: 1..4 }
  validates :source_document_id, uniqueness: { scope: :tenant_id }
  validates :ledger_event_id, uniqueness: { scope: :tenant_id }, allow_nil: true
  validates :reverses_tds_deduction_id, presence: true, if: -> { kind == "reversal" }
  validates :reverses_tds_deduction_id, absence: true, if: -> { kind == "deduction" }

  scope :for_tenant, ->(tenant_id) { where(tenant_id: tenant_id) }
  scope :in_period, ->(fiscal_year, quarter) { where(fiscal_year: fiscal_year, quarter: quarter) }

  def sign = kind == "reversal" ? -1 : 1
  def signed_taxable_minor = sign * taxable_minor
  def signed_deductible_base_minor = sign * deductible_base_minor
  def signed_tds_minor = sign * tds_minor

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
