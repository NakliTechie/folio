# frozen_string_literal: true

class KhataRecoverySnapshot < ApplicationRecord
  belongs_to :tenant
  belongs_to :khata_import_run

  validates :schema_version, inclusion: { in: [ 1 ] }
  validates :projection, :projection_sha256, presence: true
  validates :projection_sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :khata_import_run_id, uniqueness: true
  validate :scope_matches

  private

  def scope_matches
    return if tenant_id.blank? || khata_import_run.blank?
    return if khata_import_run.tenant_id == tenant_id

    errors.add(:base, ".khata recovery evidence must stay within one company")
  end
end
