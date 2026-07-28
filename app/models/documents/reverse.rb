# frozen_string_literal: true

module Documents
  # Reverse a posted document with a COMPENSATING document, never a delete (spec §7). A new
  # document with negated lines is posted; the original is marked reversed and linked both ways.
  # The append-only log already forbids deletion; this keeps the document layer honest too.
  module Reverse
    NotReversible = Class.new(StandardError)

    module_function

    def call(document, actor:, on: nil)
      raise NotReversible, "only a posted, not-yet-reversed document can be reversed" unless document.reversible?

      ActiveRecord::Base.transaction do
        date = on || document.posting_date || Date.current
        rev = Document.create!(
          tenant_id: document.tenant_id, entity_id: document.entity_id, office_id: document.office_id,
          doc_type: document.doc_type, document_type_id: document.document_type_id,
          fiscal_year: document.fiscal_year, state: "draft", reverses_document_id: document.id,
          document_date: date, posting_date: date,
          narration: "Reversal of #{document.document_number}"
        )
        document.document_lines.each do |dl|
          rev.document_lines.create!(
            tenant_id: document.tenant_id, line_no: dl.line_no, account_code: dl.account_code,
            amount_minor: -dl.amount_minor, currency: dl.currency,
            minor_unit_exponent: dl.minor_unit_exponent, narration: dl.narration
          )
        end
        entry = Documents::Post.call(rev, actor: actor)
        document.update!(state: "reversed", reversed_by_document_id: rev.id)
        entry
      end
    end
  end
end
