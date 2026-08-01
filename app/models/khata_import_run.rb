# frozen_string_literal: true

class KhataImportRun < ApplicationRecord
  belongs_to :tenant
  belongs_to :imported_by, class_name: "User"
  belongs_to :external_signing_key, optional: true
  belongs_to :domain_event

  validates :source_workspace_id, :source_filename, :archive_sha256, :books_sha256,
    :source_audit_head, :source_audit_rows, :source_manifest, :import_counts,
    :conformance, presence: true
  validates :tenant_id, uniqueness: true
  validates :archive_sha256, uniqueness: { scope: :tenant_id }
  validate :scope_matches

  private

  def scope_matches
    return if tenant_id.blank?
    return if imported_by&.memberships&.exists?(tenant_id: tenant_id) &&
      domain_event&.tenant_id == tenant_id &&
      (!external_signing_key || external_signing_key.tenant_id == tenant_id)

    errors.add(:base, ".khata import evidence must stay within one company")
  end
end
