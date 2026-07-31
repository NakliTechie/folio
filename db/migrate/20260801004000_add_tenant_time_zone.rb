# frozen_string_literal: true

class AddTenantTimeZone < ActiveRecord::Migration[8.1]
  def up
    add_column :tenants, :time_zone, :string, null: false, default: "UTC"

    execute <<~SQL.squish
      UPDATE tenants
      SET time_zone = 'Asia/Kolkata'
      WHERE id IN (
        SELECT tenant_id
        FROM entities
        WHERE code = 'PRIMARY' AND jurisdiction_profile = 'IN'
      )
    SQL
  end

  def down
    remove_column :tenants, :time_zone
  end
end
