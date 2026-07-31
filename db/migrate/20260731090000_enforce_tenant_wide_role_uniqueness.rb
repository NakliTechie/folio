# frozen_string_literal: true

class EnforceTenantWideRoleUniqueness < ActiveRecord::Migration[8.1]
  def change
    add_index :user_office_roles, %i[user_id tenant_id], unique: true,
      where: "office_id IS NULL", name: "index_user_office_roles_on_tenant_wide_assignment"
  end
end
