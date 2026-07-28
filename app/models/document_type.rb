# frozen_string_literal: true

# A document type declares HOW it posts (posting_rule) — the posting core never knows what an
# invoice is. Versioned config (D11): the event cites `version`.
class DocumentType < ApplicationRecord
  has_many :documents, dependent: :restrict_with_exception
  validates :tenant_id, :code, :label, :posting_rule, presence: true
end
