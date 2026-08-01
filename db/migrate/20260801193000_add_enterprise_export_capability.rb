# frozen_string_literal: true

class AddEnterpriseExportCapability < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, 'exports.read', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      WHERE role_templates.code IN ('accountant', 'ca_auditor')
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = 'exports.read'
        )
    SQL
  end

  def down
    execute <<~SQL.squish
      DELETE FROM role_permissions WHERE capability = 'exports.read'
    SQL
  end
end
