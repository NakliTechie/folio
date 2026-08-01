# frozen_string_literal: true

class ExternalSigningKey < ApplicationRecord
  belongs_to :tenant

  validates :source_workspace_id, :public_key_jwk, :fingerprint, presence: true
  validates :algorithm, inclusion: { in: [ "ecdsa-p256-sha256" ] }
  validates :fingerprint, uniqueness: { scope: %i[tenant_id source_workspace_id] }
end
