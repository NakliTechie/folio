# frozen_string_literal: true

require "digest"

class AccessReviewRun < ApplicationRecord
  belongs_to :tenant
  belongs_to :created_by, class_name: "User"
  belongs_to :domain_event
  has_one :access_review_attestation, dependent: :restrict_with_exception

  validates :snapshot, :snapshot_sha256, presence: true
  validates :snapshot_sha256, uniqueness: { scope: :tenant_id }
  validate :scope_matches
  validate :snapshot_digest_matches

  def digest_valid?
    snapshot_sha256 == Digest::SHA256.hexdigest(Folio::KhataHash.canonical_payload(snapshot))
  end

  private

  def scope_matches
    return if tenant_id.blank?
    return if created_by&.memberships&.exists?(tenant_id: tenant_id) && domain_event&.tenant_id == tenant_id

    errors.add(:base, "access review evidence must stay within one company")
  end

  def snapshot_digest_matches
    errors.add(:snapshot_sha256, "does not match the captured snapshot") unless digest_valid?
  end
end
