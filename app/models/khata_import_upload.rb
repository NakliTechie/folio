# frozen_string_literal: true

class KhataImportUpload < ApplicationRecord
  STATUSES = %w[queued processing succeeded failed].freeze

  belongs_to :tenant
  belongs_to :requested_by, class_name: "User"
  belongs_to :khata_import_run, optional: true

  validates :source_filename, :archive_sha256, :archive_bytes, presence: true, on: :create
  validates :archive_sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :status, inclusion: { in: STATUSES }
  validate :requester_belongs_to_tenant

  def enqueue!
    KhataImportJob.perform_later(id)
    true
  rescue StandardError => e
    update!(status: "failed", error_message: "The import could not be queued.", archive_bytes: nil)
    Rails.error.report(e, handled: true, context: { khata_import_upload_id: id })
    false
  end

  private

  def requester_belongs_to_tenant
    return if tenant_id.blank? || requested_by.blank?
    return if requested_by.memberships.exists?(tenant_id: tenant_id)

    errors.add(:base, ".khata import requests must stay within one company")
  end
end
