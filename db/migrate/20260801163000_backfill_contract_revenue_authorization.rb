# frozen_string_literal: true

# Existing tenant-scoped accountant presets need the new posting capability just as newly
# onboarded tenants do. Owner remains wildcard-authorized; other roles remain read-only.
class BackfillContractRevenueAuthorization < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, 'contracts.post', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      WHERE role_templates.code = 'accountant'
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = 'contracts.post'
        )
    SQL
  end

  def down
    execute <<~SQL.squish
      DELETE FROM role_permissions
      WHERE capability = 'contracts.post'
        AND role_template_id IN (
          SELECT id FROM role_templates WHERE code = 'accountant'
        )
    SQL
  end
end
