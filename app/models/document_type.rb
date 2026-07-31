# frozen_string_literal: true

# A document type declares HOW it posts (posting_rule) — the posting core never knows what an
# invoice is. Document types are not versioned yet; production provenance must not claim a
# config version until the append-only configuration registry exists.
class DocumentType < ApplicationRecord
  has_many :documents, dependent: :restrict_with_exception
  validates :tenant_id, :code, :label, :posting_rule, presence: true
end
