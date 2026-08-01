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
          "total_taxable_minor" => rows.sum(&:signed_taxable_minor),
          "total_tds_minor" => rows.sum(&:signed_tds_minor),
          "by_section" => by_section(rows),
          "deductees" => deductees(rows)
        }
      end

      private

      def by_section(rows)
        rows.group_by { |row| [ row.section, row.statutory_reference ] }.map do |key, group|
          section, statutory_reference = key
          { "section" => section, "statutory_reference" => statutory_reference,
            "count" => group.size,
            "taxable_minor" => group.sum(&:signed_taxable_minor),
            "tds_minor" => group.sum(&:signed_tds_minor) }
        end.sort_by { |summary| [ summary["section"], summary["statutory_reference"] ] }
      end

      def deductees(rows)
        rows.group_by(&:party_id).map do |party_id, group|
          first = group.first
          { "party_id" => party_id, "name" => first.deductee_name_snapshot, "pan" => first.deductee_pan,
            "count" => group.size, "taxable_minor" => group.sum(&:signed_taxable_minor),
            "tds_minor" => group.sum(&:signed_tds_minor),
            "deductions" => group.map { |deduction| deduction_row(deduction) } }
        end.sort_by { |deductee| deductee["name"].to_s }
      end

      def deduction_row(deduction)
        { "section" => deduction.section,
          "statutory_reference" => deduction.statutory_reference,
          "kind" => deduction.kind,
          "rate_basis_points" => deduction.rate_basis_points,
          "gross_minor" => deduction.gross_minor,
          "gst_minor" => deduction.gst_minor,
          "base_basis" => deduction.base_basis,
          "trigger_event" => deduction.trigger_event,
          "taxable_minor" => deduction.signed_taxable_minor,
          "deductible_base_minor" => deduction.sign * deduction.deductible_base_minor,
          "tds_minor" => deduction.signed_tds_minor,
          "deduction_date" => deduction.deduction_date.iso8601,
          "source_document_id" => deduction.source_document_id }
      end
    end
  end
end
