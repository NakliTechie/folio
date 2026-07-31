# frozen_string_literal: true

# The document-centric entry system (Batch 4). Namespaced explicitly so Zeitwerk resolves the
# nested services regardless of load order. Simulate previews, Post posts (allocating the
# statutory number atomically), Reverse compensates. The posting core (Posting::PostEntry)
# stays generic — a document type's posting rule is the only thing that knows its semantics.
module Documents
  # Shared: the rule a document posts under, and its fiscal-calendar identity.
  module_function

  def rule_for(document)
    id = document.document_type&.posting_rule
    raise ArgumentError, "document #{document.id} has no document_type/posting_rule" if id.blank?
    Posting::Rules.for(id)
  end

  def fiscal_year(date, variant:)
    variant == "IN_APR_MAR" && date.month < 4 ? date.year - 1 : date.year
  end

  def period_no(date, variant: "IN_APR_MAR")
    variant == "IN_APR_MAR" ? (date.month >= 4 ? date.month - 3 : date.month + 9) : date.month
  end

  def period_no_for(document)
    return 0 if document.doc_type == "OB"

    entity = Entity.find_by(tenant_id: document.tenant_id, id: document.entity_id)
    period_no(document.posting_date || document.document_date || Date.current,
      variant: entity&.fiscal_year_variant || "IN_APR_MAR")
  end
end
