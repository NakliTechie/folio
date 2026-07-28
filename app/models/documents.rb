# frozen_string_literal: true

# The document-centric entry system (Batch 4). Namespaced explicitly so Zeitwerk resolves the
# nested services regardless of load order. Simulate previews, Post posts (allocating the
# statutory number atomically), Reverse compensates. The posting core (Posting::PostEntry)
# stays generic — a document type's posting rule is the only thing that knows its semantics.
module Documents
  # Shared: the rule a document posts under, and the (fiscal_year, period_no) for its date.
  module_function

  def rule_for(document)
    id = document.document_type&.posting_rule
    raise ArgumentError, "document #{document.id} has no document_type/posting_rule" if id.blank?
    Posting::Rules.for(id)
  end

  # Indian FY period from a posting date (Apr→1 … Mar→12). Kept here so Post/Reverse agree.
  def period_no(date)
    date.month >= 4 ? date.month - 3 : date.month + 9
  end
end
