# frozen_string_literal: true

# Document identity (spec §8). The IDENTITY object only — the document-centric entry
# system (types, posting rules, lines, lifecycle) is Batch 4. external_reference drives
# duplicate-invoice detection from day one; document_number is allocated from a
# NumberRange (never a Postgres sequence) inside the posting transaction.
class Document < ApplicationRecord
  has_many :entries, dependent: :nullify

  validates :tenant_id, :entity_id, :office_id, :doc_type, :fiscal_year, presence: true
end
