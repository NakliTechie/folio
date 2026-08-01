# frozen_string_literal: true

class AccessReviewAttestation < ApplicationRecord
  belongs_to :access_review_run
  belongs_to :attested_by, class_name: "User"
  belongs_to :domain_event

  validates :notes, presence: true
  validates :outcome, inclusion: { in: Grc::Reviews::OUTCOMES }
  validates :access_review_run_id, uniqueness: true
  validate :scope_matches

  private

  def scope_matches
    return if tenant_id.blank?
    return if access_review_run&.tenant_id == tenant_id &&
      attested_by&.memberships&.exists?(tenant_id: tenant_id) && domain_event&.tenant_id == tenant_id

    errors.add(:base, "access review attestation must stay within one company")
  end
end
