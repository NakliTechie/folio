# frozen_string_literal: true

# Assigns a user a role, optionally scoped to ONE office (README §6: roles are per-office;
# office_id nil = tenant-wide). Carries the posting limit in force for that assignment.
class UserOfficeRole < ApplicationRecord
  belongs_to :user
  belongs_to :office, optional: true
  belongs_to :role_template
  belongs_to :posting_limit, optional: true
  validates :tenant_id, presence: true
  validates :user_id, uniqueness: { scope: %i[tenant_id office_id] }
  validate :role_template_belongs_to_tenant
  validate :posting_limit_belongs_to_tenant

  private

  def role_template_belongs_to_tenant
    return if role_template.blank? || tenant_id.blank? || role_template.tenant_id == tenant_id

    errors.add(:role_template, "must belong to the same company")
  end

  def posting_limit_belongs_to_tenant
    return if posting_limit.blank? || tenant_id.blank? || posting_limit.tenant_id == tenant_id

    errors.add(:posting_limit, "must belong to the same company")
  end
end
