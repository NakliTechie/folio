# frozen_string_literal: true

class EinvoiceCancellation < ApplicationRecord
  STATUSES = %w[prepared submitting cancelled rejected indeterminate].freeze
  REQUEST_FIELDS = %w[
    tenant_id einvoice_submission_id requested_by_id request_id reason_code remarks requested_at
  ].freeze
  CONCLUSION_FIELDS = %w[
    status provider attempt_count last_attempt_at cancelled_at provider_response
    provider_response_sha256 error_code error_message
  ].freeze

  belongs_to :einvoice_submission
  belongs_to :requested_by, class_name: "User"

  validates :tenant_id, :provider, :status, :request_id, :reason_code, :remarks, :requested_at,
    presence: true
  validates :einvoice_submission_id, uniqueness: true
  validates :request_id, uniqueness: { scope: :tenant_id }
  validates :status, inclusion: { in: STATUSES }
  validates :reason_code, inclusion: { in: Taxes::India::Gst::EInvoice::Cancellation::REASONS.keys }
  validates :remarks, length: { maximum: Taxes::India::Gst::EInvoice::Cancellation::MAX_REMARKS_LENGTH }
  validates :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :provider_response_sha256, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validate :scope_matches_submission
  validate :request_is_immutable, on: :update
  validate :cancelled_evidence_is_complete
  validate :cancelled_evidence_is_immutable, on: :update

  def cancelled? = status == "cancelled"
  def unresolved? = %w[submitting indeterminate].include?(status)

  private

  def scope_matches_submission
    return unless einvoice_submission && requested_by

    if einvoice_submission.tenant_id != tenant_id || !einvoice_submission.acknowledged?
      errors.add(:einvoice_submission, "must be an acknowledged IRN from the same tenant")
    end
    unless Membership.exists?(tenant_id: tenant_id, user_id: requested_by_id)
      errors.add(:requested_by, "must belong to the same tenant")
    end
  end

  def request_is_immutable
    return if (changes_to_save.keys & REQUEST_FIELDS).empty?

    errors.add(:base, "the prepared IRN cancellation request is immutable")
  end

  def cancelled_evidence_is_complete
    return unless cancelled?

    fields = %i[cancelled_at provider_response provider_response_sha256]
    errors.add(:base, "cancelled IRN evidence is incomplete") unless fields.all? { |field| public_send(field).present? }
  end

  def cancelled_evidence_is_immutable
    return unless attribute_in_database("status") == "cancelled"
    return if (changes_to_save.keys & CONCLUSION_FIELDS).empty?

    errors.add(:base, "cancelled IRN evidence is immutable")
  end
end
