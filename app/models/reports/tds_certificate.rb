# frozen_string_literal: true

module Reports
  # Form 16A — the TDS certificate a deductor issues to a deductee for non-salary payments.
  #
  # NOTE ON THE FORM NUMBER: the correct certificate for a 26Q return is Form 16A. Bahi labels
  # its TDS certificate "27D", but 27D is actually the TCS certificate (paired with the 27EQ
  # return); Folio uses the correct 16A. Independent clean build, Bahi as the oracle — and here
  # the oracle is wrong, so Folio is right.
  #
  # Structured data over tds_deductions; PDF rendering is a follow-up.
  class TdsCertificate
    class << self
      def call(tenant_id:, party_id:, fiscal_year:, quarter:)
        party_id = Integer(party_id)
        rows = TdsDeduction.for_tenant(tenant_id).in_period(fiscal_year, quarter)
          .where(party_id: party_id).order(:deduction_date, :id).to_a
        entity = Entity.find_by(tenant_id: tenant_id, code: "PRIMARY")

        {
          "form" => "16A",
          "fiscal_year" => fiscal_year,
          "quarter" => quarter,
          "deductor" => { "name" => entity&.legal_name },
          "deductee" => {
            "party_id" => party_id,
            "name" => rows.first&.deductee_name_snapshot,
            "pan" => rows.first&.deductee_pan
          },
          "total_taxable_minor" => rows.sum(&:signed_taxable_minor),
          "total_tds_minor" => rows.sum(&:signed_tds_minor),
          "deductions" => rows.map do |deduction|
            { "section" => deduction.section,
              "statutory_reference" => deduction.statutory_reference,
              "kind" => deduction.kind,
              "rate_basis_points" => deduction.rate_basis_points,
              "gross_minor" => deduction.gross_minor,
              "gst_minor" => deduction.gst_minor,
              "base_basis" => deduction.base_basis,
              "trigger_event" => deduction.trigger_event,
              "taxable_minor" => deduction.signed_taxable_minor,
              "deductible_base_minor" => deduction.signed_deductible_base_minor,
              "tds_minor" => deduction.signed_tds_minor,
              "deduction_date" => deduction.deduction_date.iso8601,
              "source_document_id" => deduction.source_document_id }
          end
        }
      end
    end
  end
end
