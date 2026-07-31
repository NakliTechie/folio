# frozen_string_literal: true

class OfficeTaxRegistration < ApplicationRecord
  belongs_to :office
  belongs_to :tax_registration

  validates :tenant_id, presence: true
  validates :tax_registration_id, uniqueness: { scope: :office_id }
  validate :references_share_tenant_and_entity

  private

  def references_share_tenant_and_entity
    return unless office && tax_registration

    valid = office.tenant_id == tenant_id && tax_registration.tenant_id == tenant_id &&
      office.entity_id == tax_registration.entity_id
    errors.add(:base, "office and registration must share a tenant and entity") unless valid
  end
end
