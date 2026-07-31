# frozen_string_literal: true

module Documents
  module UpdateJournalDraft
    module_function

    def call!(document:, posting_date:, narration:, lines:)
      posting_on = BuildDraft.parse_date!(posting_date, "posting date")
      tenant = Tenant.find(document.tenant_id)
      entity = Entity.find_by!(tenant_id: tenant.id, id: document.entity_id)
      normalized_lines = BuildDraft.normalize_lines!(tenant, lines)

      Document.transaction do
        document.lock!
        unless document.doc_type == "JV" && document.postable? &&
               document.posted_entry_id.nil? && document.document_number.nil?
          raise InvalidDocument, "only an unposted, unnumbered journal draft can be edited"
        end

        document.update!(
          document_date: posting_on,
          posting_date: posting_on,
          fiscal_year: Documents.fiscal_year(posting_on, variant: entity.fiscal_year_variant),
          narration: narration
        )
        document.document_lines.destroy_all
        normalized_lines.each_with_index do |line, index|
          document.document_lines.create!(
            tenant_id: tenant.id,
            line_no: index + 1,
            account_code: line.fetch(:account_code),
            amount_minor: line.fetch(:amount_minor),
            currency: line.fetch(:currency),
            minor_unit_exponent: line.fetch(:minor_unit_exponent),
            narration: line[:narration] || narration,
            extra: line[:extra]
          )
        end
        Posting::Rules::JournalVoucher.validate_document!(document)
        document
      end
    end
  end
end
