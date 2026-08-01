# frozen_string_literal: true

# One idempotent statutory submission envelope per posted sales document. The request payload is
# frozen at preparation; only lifecycle/evidence fields may change as an IRP adapter runs.
class EinvoiceSubmission < ApplicationRecord
  STATUSES = %w[prepared submitting acknowledged rejected indeterminate].freeze
  SIGNATURE_STATUSES = %w[not_checked provider_verified locally_verified failed].freeze
  REQUEST_FIELDS = %w[
    tenant_id document_id tax_registration_id schema_version request_id payload payload_sha256
  ].freeze
  ACKNOWLEDGEMENT_FIELDS = %w[
    status provider attempt_count last_attempt_at irn ack_number acknowledged_at signed_invoice
    signed_qr_code signature_status provider_response provider_response_sha256 error_code error_message
  ].freeze

  belongs_to :document
  belongs_to :tax_registration

  validates :tenant_id, :provider, :status, :schema_version, :request_id,
    :payload, :payload_sha256, :signature_status, presence: true
  validates :document_id, uniqueness: { scope: :tenant_id }
  validates :request_id, uniqueness: { scope: :tenant_id }
  validates :status, inclusion: { in: STATUSES }
  validates :signature_status, inclusion: { in: SIGNATURE_STATUSES }
  validates :payload_sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :provider_response_sha256,
    format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :irn, format: { with: /\A[0-9a-fA-F]{64}\z/ }, allow_nil: true
  validates :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :scope_matches_document
  validate :payload_is_immutable, on: :update
  validate :acknowledgement_is_complete
  validate :acknowledgement_is_immutable, on: :update

  def acknowledged? = status == "acknowledged"
  def unresolved? = %w[submitting indeterminate].include?(status)

  private

  def scope_matches_document
    return unless document && tax_registration

    errors.add(:document, "must belong to the same tenant") if document.tenant_id != tenant_id
    if tax_registration.tenant_id != tenant_id || document.tax_registration_id != tax_registration_id
      errors.add(:tax_registration, "must be the document's tenant-scoped seller registration")
    end
    unless %w[SI CN].include?(document.doc_type) && document.posted?
      errors.add(:document, "must be a posted sales invoice or credit note")
    end
  end

  def payload_is_immutable
    return if (changes_to_save.keys & REQUEST_FIELDS).empty?

    errors.add(:base, "the prepared e-invoice request is immutable")
  end

  def acknowledgement_is_complete
    return unless acknowledged?

    fields = %i[irn ack_number acknowledged_at signed_invoice signed_qr_code
                provider_response provider_response_sha256]
    errors.add(:base, "acknowledged IRP evidence is incomplete") unless fields.all? { |field| public_send(field).present? }
  end

  def acknowledgement_is_immutable
    return unless attribute_in_database("status") == "acknowledged"
    return if (changes_to_save.keys & ACKNOWLEDGEMENT_FIELDS).empty?

    errors.add(:base, "acknowledged IRP evidence is immutable")
  end
end
