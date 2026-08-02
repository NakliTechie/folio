# frozen_string_literal: true

class ForceTenantRowSecurity < ActiveRecord::Migration[8.1]
  # These control-plane tables resolve a user's permitted tenant before context is set.
  # The non-owner runtime role still prevents DDL against them.
  EXCLUDED = %w[
    invitations khata_import_uploads memberships posting_limits role_templates
    sod_conflict_rules user_office_roles
  ].freeze

  def up
    tenant_tables.each do |table|
      execute <<~SQL
        ALTER TABLE #{quote_table_name(table)} ENABLE ROW LEVEL SECURITY;
        ALTER TABLE #{quote_table_name(table)} FORCE ROW LEVEL SECURITY;
        CREATE POLICY folio_tenant_isolation ON #{quote_table_name(table)}
          USING (tenant_id = NULLIF(current_setting('folio.tenant_id', true), '')::bigint)
          WITH CHECK (tenant_id = NULLIF(current_setting('folio.tenant_id', true), '')::bigint);
      SQL
    end
  end

  def down
    tenant_tables.each do |table|
      execute <<~SQL
        DROP POLICY IF EXISTS folio_tenant_isolation ON #{quote_table_name(table)};
        ALTER TABLE #{quote_table_name(table)} NO FORCE ROW LEVEL SECURITY;
        ALTER TABLE #{quote_table_name(table)} DISABLE ROW LEVEL SECURITY;
      SQL
    end
  end

  private

  def tenant_tables
    @tenant_tables ||= connection.tables.select do |table|
      connection.column_exists?(table, :tenant_id) && !EXCLUDED.include?(table)
    end.sort
  end
end
