# frozen_string_literal: true

module Reports
  # Form 26Q — the quarterly return of TDS on non-salary payments to residents. A book-derived
  # preparation view over tds_deductions: a deductor summary, a per-section roll-up, and the
  # deductee-wise breakup the return requires. Structured data; NSDL/CSV export is a follow-up.
  class TdsReturn
    class << self
      def call(tenant_id:, fiscal_year:, quarter:)
        rows = TdsDeduction.for_tenant(tenant_id).in_period(fiscal_year, quarter)
          .order(:party_id, :deduction_date, :id).to_a

        {
          "form" => "26Q",
          "fiscal_year" => fiscal_year,
          "quarter" => quarter,
          "deduction_count" => rows.size,
          "total_taxable_minor" => rows.sum(&:taxable_minor),
          "total_tds_minor" => rows.sum(&:tds_minor),
          "by_section" => by_section(rows),
          "deductees" => deductees(rows)
        }
      end

      private

      def by_section(rows)
        rows.group_by(&:section).map do |section, group|
          { "section" => section, "count" => group.size,
            "taxable_minor" => group.sum(&:taxable_minor), "tds_minor" => group.sum(&:tds_minor) }
        end.sort_by { |summary| summary["section"] }
      end

      def deductees(rows)
        rows.group_by(&:party_id).map do |party_id, group|
          first = group.first
          { "party_id" => party_id, "name" => first.deductee_name_snapshot, "pan" => first.deductee_pan,
            "count" => group.size, "taxable_minor" => group.sum(&:taxable_minor),
            "tds_minor" => group.sum(&:tds_minor),
            "deductions" => group.map { |deduction| deduction_row(deduction) } }
        end.sort_by { |deductee| deductee["name"].to_s }
      end

      def deduction_row(deduction)
        { "section" => deduction.section, "rate_basis_points" => deduction.rate_basis_points,
          "taxable_minor" => deduction.taxable_minor, "tds_minor" => deduction.tds_minor,
          "deduction_date" => deduction.deduction_date.iso8601,
          "source_document_id" => deduction.source_document_id }
      end
    end
  end
end
