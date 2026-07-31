# frozen_string_literal: true

class HardenTenantRoleAssignments < ActiveRecord::Migration[8.1]
  def up
    add_index :role_templates, %i[id tenant_id], unique: true,
      name: "idx_role_templates_id_tenant"
    add_index :posting_limits, %i[id tenant_id], unique: true,
      name: "idx_posting_limits_id_tenant"

    execute <<~SQL
      ALTER TABLE user_office_roles
        ADD CONSTRAINT fk_user_roles_same_tenant
        FOREIGN KEY (role_template_id, tenant_id)
        REFERENCES role_templates (id, tenant_id);
      ALTER TABLE user_office_roles
        ADD CONSTRAINT fk_user_limits_same_tenant
        FOREIGN KEY (posting_limit_id, tenant_id)
        REFERENCES posting_limits (id, tenant_id);
    SQL

    execute <<~SQL
      CREATE FUNCTION folio_protect_last_tenant_owner() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        old_was_owner boolean;
        new_is_same_tenant_owner boolean := false;
        another_owner_exists boolean;
      BEGIN
        SELECT EXISTS (
          SELECT 1 FROM role_templates
          WHERE id = OLD.role_template_id
            AND tenant_id = OLD.tenant_id
            AND code = 'owner'
        ) AND OLD.office_id IS NULL INTO old_was_owner;

        IF NOT old_was_owner THEN
          RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
        END IF;

        IF TG_OP = 'UPDATE' THEN
          SELECT EXISTS (
            SELECT 1 FROM role_templates
            WHERE id = NEW.role_template_id
              AND tenant_id = OLD.tenant_id
              AND code = 'owner'
          ) AND NEW.office_id IS NULL AND NEW.tenant_id = OLD.tenant_id
          INTO new_is_same_tenant_owner;
        END IF;

        IF new_is_same_tenant_owner THEN
          RETURN NEW;
        END IF;

        PERFORM pg_advisory_xact_lock(OLD.tenant_id);
        SELECT EXISTS (
          SELECT 1
          FROM user_office_roles assignments
          INNER JOIN role_templates roles ON roles.id = assignments.role_template_id
          WHERE assignments.tenant_id = OLD.tenant_id
            AND assignments.office_id IS NULL
            AND assignments.id <> OLD.id
            AND roles.tenant_id = OLD.tenant_id
            AND roles.code = 'owner'
        ) INTO another_owner_exists;

        IF NOT another_owner_exists THEN
          RAISE EXCEPTION 'a tenant must retain at least one owner'
            USING ERRCODE = '23514', CONSTRAINT = 'tenant_requires_owner';
        END IF;

        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
      END;
      $$;

      CREATE TRIGGER protect_last_tenant_owner
      BEFORE UPDATE OR DELETE ON user_office_roles
      FOR EACH ROW EXECUTE FUNCTION folio_protect_last_tenant_owner();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS protect_last_tenant_owner ON user_office_roles"
    execute "DROP FUNCTION IF EXISTS folio_protect_last_tenant_owner()"
    execute "ALTER TABLE user_office_roles DROP CONSTRAINT IF EXISTS fk_user_limits_same_tenant"
    execute "ALTER TABLE user_office_roles DROP CONSTRAINT IF EXISTS fk_user_roles_same_tenant"
    remove_index :posting_limits, name: "idx_posting_limits_id_tenant"
    remove_index :role_templates, name: "idx_role_templates_id_tenant"
  end
end
