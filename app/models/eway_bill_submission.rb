# frozen_string_literal: true

# Immutable transport instructions for e-way-bill generation through an invoice's IRN. Provider
# credentials never belong here; only bounded acknowledgement evidence may conclude the lifecycle.
class EwayBillSubmission < ApplicationRecord
  STATUSES = %w[prepared generated].freeze
  REQUEST_FIELDS = %w[
    tenant_id document_id requested_by_id schema_version request_id payload payload_sha256
  ].freeze
  GENERATION_FIELDS = %w[
    provider status eway_bill_number generated_at valid_until provider_response
    provider_response_sha256
  ].freeze

  belongs_to :document
  belongs_to :requested_by, class_name: "User"

  validates :tenant_id, :provider, :status, :schema_version, :request_id, :payload,
    :payload_sha256, presence: true
  validates :document_id, uniqueness: { scope: :tenant_id }
  validates :request_id, uniqueness: { scope: :tenant_id }
  validates :eway_bill_number, uniqueness: { scope: :tenant_id }, allow_nil: true
  validates :status, inclusion: { in: STATUSES }
  validates :payload_sha256, :provider_response_sha256,
    format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :eway_bill_number, format: { with: /\A\d{12}\z/ }, allow_nil: true
  validate :scope_matches_document
  validate :request_is_immutable, on: :update
  validate :generation_is_complete
  validate :generation_is_immutable, on: :update

  def generated? = status == "generated"

  private

  def scope_matches_document
    return unless document && requested_by

    unless document.tenant_id == tenant_id && document.doc_type == "SI" && document.posted?
      errors.add(:document, "must be a posted sales invoice from the same company")
    end
    membership_scope_changed = new_record? || will_save_change_to_tenant_id? ||
      will_save_change_to_requested_by_id?
    if membership_scope_changed && !Membership.exists?(tenant_id: tenant_id, user_id: requested_by_id)
      errors.add(:requested_by, "must belong to the same company")
    end
  end

  def request_is_immutable
    return if (changes_to_save.keys & REQUEST_FIELDS).empty?

    errors.add(:base, "the prepared e-way bill request is immutable")
  end

  def generation_is_complete
    return unless generated?

    fields = %i[eway_bill_number generated_at valid_until provider_response provider_response_sha256]
    errors.add(:base, "generated e-way bill evidence is incomplete") unless fields.all? { |field| public_send(field).present? }
    errors.add(:valid_until, "must follow generation") if generated_at && valid_until && valid_until <= generated_at
  end

  def generation_is_immutable
    return unless attribute_in_database("status") == "generated"
    return if (changes_to_save.keys & GENERATION_FIELDS).empty?

    errors.add(:base, "generated e-way bill evidence is immutable")
  end
end
