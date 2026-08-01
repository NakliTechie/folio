# frozen_string_literal: true

# Batch 9: management-accounting dimensions and auditable cost-center allocation.
# Actual allocations remain ordinary universal-journal postings; plan is shaped by the
# same account + cost-center + fiscal-period coordinates without touching the legal books.
class CreateControlling < ActiveRecord::Migration[8.1]
  def up
    create_table :controlling_segments do |t|
      t.bigint :tenant_id, null: false
      t.string :code, null: false
      t.string :name, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :controlling_segments, %i[tenant_id code], unique: true

    create_table :profit_centers do |t|
      t.bigint :tenant_id, null: false
      t.references :entity, null: false, foreign_key: true
      t.references :controlling_segment, null: false, foreign_key: true
      t.string :code, null: false
      t.string :name, null: false
      t.date :valid_from, null: false
      t.date :valid_to
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :profit_centers, %i[tenant_id code], unique: true
    add_check_constraint :profit_centers, "valid_to IS NULL OR valid_to >= valid_from",
      name: "profit_centers_range_valid"

    create_table :cost_centers do |t|
      t.bigint :tenant_id, null: false
      t.references :entity, null: false, foreign_key: true
      t.references :profit_center, null: false, foreign_key: true
      t.string :code, null: false
      t.string :name, null: false
      t.date :valid_from, null: false
      t.date :valid_to
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :cost_centers, %i[tenant_id code], unique: true
    add_check_constraint :cost_centers, "valid_to IS NULL OR valid_to >= valid_from",
      name: "cost_centers_range_valid"

    create_table :controlling_plan_lines do |t|
      t.bigint :tenant_id, null: false
      t.references :cost_center, null: false, foreign_key: true
      t.string :account_code, null: false
      t.string :version, null: false, default: "BUDGET"
      t.integer :fiscal_year, null: false
      t.integer :period_no, null: false
      t.string :currency, null: false
      t.bigint :amount_minor, null: false
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :controlling_plan_lines,
      %i[tenant_id version fiscal_year period_no cost_center_id account_code], unique: true,
      name: "index_controlling_plan_lines_on_coordinate"
    add_check_constraint :controlling_plan_lines, "period_no BETWEEN 1 AND 16",
      name: "controlling_plan_lines_period_valid"

    create_table :allocation_cycles do |t|
      t.bigint :tenant_id, null: false
      t.references :entity, null: false, foreign_key: true
      t.references :office, null: false, foreign_key: true
      t.references :sender_cost_center, null: false, foreign_key: { to_table: :cost_centers }
      t.string :code, null: false
      t.string :name, null: false
      t.string :allocation_type, null: false, default: "distribution"
      t.string :source_account_code, null: false
      t.date :valid_from, null: false
      t.date :valid_to
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :allocation_cycles, %i[tenant_id code], unique: true
    add_check_constraint :allocation_cycles, "allocation_type = 'distribution'",
      name: "allocation_cycles_type_valid"
    add_check_constraint :allocation_cycles, "valid_to IS NULL OR valid_to >= valid_from",
      name: "allocation_cycles_range_valid"

    create_table :allocation_receivers do |t|
      t.bigint :tenant_id, null: false
      t.references :allocation_cycle, null: false, foreign_key: true
      t.references :cost_center, null: false, foreign_key: true
      t.integer :weight_basis_points, null: false
      t.timestamps
    end
    add_index :allocation_receivers, %i[allocation_cycle_id cost_center_id], unique: true,
      name: "index_allocation_receivers_on_cycle_and_center"
    add_check_constraint :allocation_receivers, "weight_basis_points BETWEEN 1 AND 10000",
      name: "allocation_receivers_weight_valid"

    create_table :allocation_runs do |t|
      t.bigint :tenant_id, null: false
      t.references :allocation_cycle, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.bigint :ledger_event_id
      t.string :idempotency_key, null: false
      t.string :request_sha256, null: false
      t.string :mode, null: false
      t.string :status, null: false
      t.date :period_start, null: false
      t.date :through_date, null: false
      t.date :posting_date, null: false
      t.bigint :allocated_amount_minor, null: false, default: 0
      t.jsonb :result, null: false, default: {}
      t.timestamps
    end
    add_index :allocation_runs, %i[tenant_id idempotency_key], unique: true
    add_check_constraint :allocation_runs, "mode IN ('simulate', 'post')",
      name: "allocation_runs_mode_valid"
    add_check_constraint :allocation_runs, "status IN ('simulated', 'posted')",
      name: "allocation_runs_status_valid"
    add_check_constraint :allocation_runs, "allocated_amount_minor >= 0",
      name: "allocation_runs_amount_nonnegative"
    add_check_constraint :allocation_runs, "through_date >= period_start",
      name: "allocation_runs_dates_valid"

    create_table :allocation_run_items do |t|
      t.bigint :tenant_id, null: false
      t.references :allocation_run, null: false, foreign_key: true
      t.references :sender_cost_center, null: false, foreign_key: { to_table: :cost_centers }
      t.references :receiver_cost_center, null: false, foreign_key: { to_table: :cost_centers }
      t.string :account_code, null: false
      t.integer :weight_basis_points, null: false
      t.bigint :amount_minor, null: false
      t.timestamps
    end
    add_index :allocation_run_items, %i[allocation_run_id receiver_cost_center_id], unique: true,
      name: "index_allocation_run_items_on_receiver"
    add_check_constraint :allocation_run_items, "amount_minor > 0",
      name: "allocation_run_items_amount_positive"

    execute <<~SQL
      CREATE FUNCTION folio_controlling_evidence_immutable() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '% is immutable: % on row id=% rejected', TG_TABLE_NAME, TG_OP, OLD.id;
      END;
      $$;

      CREATE TRIGGER allocation_runs_immutable
        BEFORE UPDATE OR DELETE ON allocation_runs
        FOR EACH ROW EXECUTE FUNCTION folio_controlling_evidence_immutable();
      CREATE TRIGGER allocation_run_items_immutable
        BEFORE UPDATE OR DELETE ON allocation_run_items
        FOR EACH ROW EXECUTE FUNCTION folio_controlling_evidence_immutable();
    SQL

    seed_defaults
    seed_permissions
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS allocation_run_items_immutable ON allocation_run_items;
      DROP TRIGGER IF EXISTS allocation_runs_immutable ON allocation_runs;
      DROP FUNCTION IF EXISTS folio_controlling_evidence_immutable();
    SQL
    drop_table :allocation_run_items
    drop_table :allocation_runs
    drop_table :allocation_receivers
    drop_table :allocation_cycles
    drop_table :controlling_plan_lines
    drop_table :cost_centers
    drop_table :profit_centers
    drop_table :controlling_segments
  end

  private

  def seed_defaults
    now = connection.quote(Time.current)
    execute <<~SQL.squish
      INSERT INTO controlling_segments (tenant_id, code, name, active, created_at, updated_at)
      SELECT tenants.id, 'UNASSIGNED', 'Unassigned segment', TRUE, #{now}, #{now} FROM tenants
    SQL
    execute <<~SQL.squish
      INSERT INTO profit_centers
        (tenant_id, entity_id, controlling_segment_id, code, name, valid_from, active, created_at, updated_at)
      SELECT entities.tenant_id, entities.id, controlling_segments.id, 'UNASSIGNED',
             'Unassigned profit center', DATE '1900-01-01', TRUE, #{now}, #{now}
      FROM entities
      JOIN controlling_segments ON controlling_segments.tenant_id = entities.tenant_id
        AND controlling_segments.code = 'UNASSIGNED'
      WHERE entities.code = 'PRIMARY'
    SQL
    execute <<~SQL.squish
      INSERT INTO cost_centers
        (tenant_id, entity_id, profit_center_id, code, name, valid_from, active, created_at, updated_at)
      SELECT profit_centers.tenant_id, profit_centers.entity_id, profit_centers.id, 'GENERAL',
             'General overhead', DATE '1900-01-01', TRUE, #{now}, #{now}
      FROM profit_centers WHERE profit_centers.code = 'UNASSIGNED'
    SQL
  end

  def seed_permissions
    execute <<~SQL.squish
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, capabilities.capability, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      CROSS JOIN (VALUES ('controlling.read'), ('controlling.manage'), ('controlling.allocate'))
        AS capabilities(capability)
      WHERE role_templates.code = 'accountant'
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = capabilities.capability
        )
    SQL
    execute <<~SQL.squish
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, 'controlling.read', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      WHERE role_templates.code IN ('ca_auditor', 'viewer')
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = 'controlling.read'
        )
    SQL
  end
end
