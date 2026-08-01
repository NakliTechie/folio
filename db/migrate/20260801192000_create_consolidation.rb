# frozen_string_literal: true

# Batch 9: same-functional-currency group reporting, matched-by-construction
# intercompany postings, and append-only elimination evidence.
class CreateConsolidation < ActiveRecord::Migration[8.1]
  def up
    create_table :consolidation_groups do |t|
      t.bigint :tenant_id, null: false
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :code, null: false
      t.string :name, null: false
      t.string :presentation_currency, null: false, limit: 3
      t.timestamps
    end
    add_index :consolidation_groups, %i[tenant_id code], unique: true

    create_table :consolidation_group_members do |t|
      t.bigint :tenant_id, null: false
      t.references :consolidation_group, null: false, foreign_key: true
      t.references :entity, null: false, foreign_key: true
      t.integer :ownership_basis_points, null: false, default: 10_000
      t.date :effective_from, null: false
      t.date :effective_to
      t.timestamps
    end
    add_index :consolidation_group_members, %i[consolidation_group_id entity_id],
      unique: true, name: "index_consolidation_members_on_group_entity"
    add_check_constraint :consolidation_group_members,
      "ownership_basis_points = 10000",
      name: "consolidation_members_ownership_valid"
    add_check_constraint :consolidation_group_members,
      "effective_to IS NULL OR effective_to >= effective_from",
      name: "consolidation_members_dates_valid"

    execute <<~SQL.squish
      INSERT INTO consolidation_groups
        (tenant_id, created_by_id, code, name, presentation_currency, created_at, updated_at)
      SELECT tenants.id, MIN(memberships.user_id), 'GROUP', tenants.name || ' Group',
        tenants.functional_currency, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM tenants
      JOIN memberships ON memberships.tenant_id = tenants.id
      GROUP BY tenants.id, tenants.name, tenants.functional_currency
    SQL
    execute <<~SQL.squish
      INSERT INTO consolidation_group_members
        (tenant_id, consolidation_group_id, entity_id, ownership_basis_points,
         effective_from, created_at, updated_at)
      SELECT entities.tenant_id, consolidation_groups.id, entities.id, 10000,
        DATE '1900-01-01', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM entities
      JOIN consolidation_groups ON consolidation_groups.tenant_id = entities.tenant_id
    SQL

    create_table :intercompany_transactions do |t|
      t.bigint :tenant_id, null: false
      t.references :consolidation_group, null: false, foreign_key: true
      t.references :seller_entity, null: false, foreign_key: { to_table: :entities }
      t.references :buyer_entity, null: false, foreign_key: { to_table: :entities }
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      # Deliberately no FK: ledger_events owns an append-only TRUNCATE guard and
      # must not be pre-empted by dependent-table referential checks.
      t.references :ledger_event, null: false
      t.string :transaction_code, null: false
      t.string :idempotency_key, null: false
      t.string :request_sha256, null: false
      t.date :posting_date, null: false
      t.string :currency, null: false, limit: 3
      t.bigint :amount_minor, null: false
      t.string :description, null: false
      t.timestamps
    end
    add_index :intercompany_transactions, %i[tenant_id transaction_code], unique: true,
      name: "index_intercompany_transactions_on_code"
    add_index :intercompany_transactions, %i[tenant_id idempotency_key], unique: true,
      name: "index_intercompany_transactions_on_idempotency"
    add_check_constraint :intercompany_transactions, "seller_entity_id <> buyer_entity_id",
      name: "intercompany_transactions_distinct_entities"
    add_check_constraint :intercompany_transactions, "amount_minor > 0",
      name: "intercompany_transactions_amount_positive"

    create_table :consolidation_elimination_runs do |t|
      t.bigint :tenant_id, null: false
      t.references :consolidation_group, null: false, foreign_key: true
      t.references :intercompany_transaction, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      # Deliberately no FK; see the intercompany transaction reference above.
      t.references :ledger_event, null: false
      t.string :idempotency_key, null: false
      t.string :request_sha256, null: false
      t.date :posting_date, null: false
      t.timestamps
    end
    add_index :consolidation_elimination_runs, %i[tenant_id idempotency_key], unique: true,
      name: "index_consolidation_eliminations_on_idempotency"
    add_index :consolidation_elimination_runs, :intercompany_transaction_id, unique: true,
      name: "index_consolidation_eliminations_on_transaction"

    execute <<~SQL
      CREATE FUNCTION folio_consolidation_evidence_immutable() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '% is immutable: % on row id=% rejected', TG_TABLE_NAME, TG_OP, OLD.id;
      END;
      $$;
      CREATE TRIGGER intercompany_transactions_immutable
        BEFORE UPDATE OR DELETE ON intercompany_transactions
        FOR EACH ROW EXECUTE FUNCTION folio_consolidation_evidence_immutable();
      CREATE TRIGGER consolidation_elimination_runs_immutable
        BEFORE UPDATE OR DELETE ON consolidation_elimination_runs
        FOR EACH ROW EXECUTE FUNCTION folio_consolidation_evidence_immutable();
    SQL

    seed_permissions
  end

  def down
    execute <<~SQL.squish
      DELETE FROM role_permissions
      WHERE capability IN ('consolidation.read', 'consolidation.manage', 'consolidation.post')
    SQL
    execute <<~SQL
      DROP TRIGGER IF EXISTS consolidation_elimination_runs_immutable ON consolidation_elimination_runs;
      DROP TRIGGER IF EXISTS intercompany_transactions_immutable ON intercompany_transactions;
      DROP FUNCTION IF EXISTS folio_consolidation_evidence_immutable();
    SQL
    drop_table :consolidation_elimination_runs
    drop_table :intercompany_transactions
    drop_table :consolidation_group_members
    drop_table :consolidation_groups
  end

  private

  def seed_permissions
    execute <<~SQL.squish
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, capabilities.capability, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      CROSS JOIN (VALUES
        ('consolidation.read'), ('consolidation.manage'), ('consolidation.post')
      ) AS capabilities(capability)
      WHERE role_templates.code = 'accountant'
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = capabilities.capability
        )
    SQL
    execute <<~SQL.squish
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, 'consolidation.read', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      WHERE role_templates.code IN ('ca_auditor', 'viewer')
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = 'consolidation.read'
        )
    SQL
  end
end
