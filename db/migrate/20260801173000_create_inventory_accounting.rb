# frozen_string_literal: true

# Batch 9: concurrency-safe moving-average inventory. The immutable movements keep the
# exact value consumed by each issue; stock_balances are a lockable, rebuildable projection.
class CreateInventoryAccounting < ActiveRecord::Migration[8.1]
  def up
    add_column :items, :inventory_class, :string
    add_column :items, :revision, :string
    add_column :items, :valuation_method, :string
    add_column :items, :inventory_account_code, :string
    now = connection.quote(Time.current)
    execute <<~SQL.squish
      INSERT INTO accounts (tenant_id, code, name, account_type, active, monetary, created_at, updated_at)
      SELECT tenants.id, seeded.code, seeded.name, seeded.account_type, TRUE, FALSE, #{now}, #{now}
      FROM tenants
      CROSS JOIN (VALUES
        ('1300', 'Inventory', 'asset'),
        ('5050', 'Inventory Adjustments', 'expense')
      ) AS seeded(code, name, account_type)
      WHERE NOT EXISTS (
        SELECT 1 FROM accounts
        WHERE accounts.tenant_id = tenants.id AND accounts.code = seeded.code
      )
    SQL
    execute <<~SQL.squish
      UPDATE items
      SET inventory_class = 'trading', revision = 'A', valuation_method = 'moving_average',
          inventory_account_code = '1300'
      WHERE item_type = 'good'
    SQL
    add_check_constraint :items,
      <<~SQL.squish, name: "items_inventory_profile_coherent"
        (item_type = 'service' AND inventory_class IS NULL AND revision IS NULL
          AND valuation_method IS NULL AND inventory_account_code IS NULL)
        OR
        (item_type = 'good' AND inventory_class IN ('raw_material', 'wip', 'finished_good', 'trading')
          AND revision IS NOT NULL AND valuation_method = 'moving_average'
          AND inventory_account_code IS NOT NULL)
      SQL

    create_table :warehouses do |t|
      t.bigint :tenant_id, null: false
      t.references :entity, null: false, foreign_key: true
      t.references :office, null: false, foreign_key: true
      t.string :code, null: false
      t.string :name, null: false
      t.string :warehouse_type, null: false, default: "general"
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :warehouses, %i[tenant_id code], unique: true
    add_check_constraint :warehouses,
      "warehouse_type IN ('general', 'raw_material', 'wip', 'finished_goods')",
      name: "warehouses_type_valid"

    execute <<~SQL.squish
      INSERT INTO warehouses
        (tenant_id, entity_id, office_id, code, name, warehouse_type, active, created_at, updated_at)
      SELECT offices.tenant_id, offices.entity_id, offices.id, 'MAIN', 'Main warehouse',
             'general', TRUE, #{now}, #{now}
      FROM offices
      WHERE offices.code = 'PRIMARY'
        AND NOT EXISTS (
          SELECT 1 FROM warehouses
          WHERE warehouses.tenant_id = offices.tenant_id AND warehouses.code = 'MAIN'
        )
    SQL

    create_table :stock_balances do |t|
      t.bigint :tenant_id, null: false
      t.references :item, null: false, foreign_key: true
      t.references :warehouse, null: false, foreign_key: true
      t.decimal :quantity, precision: 20, scale: 6, null: false, default: 0
      t.bigint :inventory_value_minor, null: false, default: 0
      t.bigint :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :stock_balances, %i[tenant_id item_id warehouse_id], unique: true,
      name: "index_stock_balances_on_position"
    add_check_constraint :stock_balances, "quantity >= 0", name: "stock_balances_nonnegative_quantity"
    add_check_constraint :stock_balances, "inventory_value_minor >= 0",
      name: "stock_balances_nonnegative_value"
    add_check_constraint :stock_balances,
      "(quantity = 0 AND inventory_value_minor = 0) OR quantity > 0",
      name: "stock_balances_zero_position_coherent"

    create_table :inventory_transactions do |t|
      t.bigint :tenant_id, null: false
      t.references :entity, null: false, foreign_key: true
      t.references :office, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :item, null: false, foreign_key: true
      t.references :source_warehouse, foreign_key: { to_table: :warehouses }
      t.references :destination_warehouse, foreign_key: { to_table: :warehouses }
      t.bigint :ledger_event_id, null: false
      t.string :idempotency_key, null: false
      t.string :request_sha256, null: false
      t.string :transaction_type, null: false
      t.date :posting_date, null: false
      t.decimal :quantity, precision: 20, scale: 6, null: false
      t.bigint :unit_cost_minor
      t.bigint :total_value_minor, null: false
      t.string :offset_account_code
      t.string :external_reference
      t.string :reason, null: false
      t.timestamps
    end
    add_index :inventory_transactions, %i[tenant_id idempotency_key], unique: true,
      name: "index_inventory_transactions_on_idempotency"
    add_index :inventory_transactions, %i[tenant_id posting_date],
      name: "index_inventory_transactions_on_posting_date"
    add_check_constraint :inventory_transactions,
      "transaction_type IN ('receipt', 'issue', 'transfer', 'adjustment_in', 'adjustment_out')",
      name: "inventory_transactions_type_valid"
    add_check_constraint :inventory_transactions, "quantity > 0",
      name: "inventory_transactions_quantity_positive"
    add_check_constraint :inventory_transactions, "total_value_minor > 0",
      name: "inventory_transactions_value_positive"
    add_check_constraint :inventory_transactions,
      <<~SQL.squish, name: "inventory_transactions_warehouse_coherent"
        (transaction_type IN ('issue', 'adjustment_out') AND source_warehouse_id IS NOT NULL
          AND destination_warehouse_id IS NULL AND offset_account_code IS NOT NULL)
        OR
        (transaction_type IN ('receipt', 'adjustment_in') AND source_warehouse_id IS NULL
          AND destination_warehouse_id IS NOT NULL AND offset_account_code IS NOT NULL
          AND unit_cost_minor IS NOT NULL)
        OR
        (transaction_type = 'transfer' AND source_warehouse_id IS NOT NULL
          AND destination_warehouse_id IS NOT NULL AND source_warehouse_id <> destination_warehouse_id
          AND offset_account_code IS NULL)
      SQL

    create_table :inventory_movements do |t|
      t.bigint :tenant_id, null: false
      t.references :inventory_transaction, null: false, foreign_key: true,
        index: { name: "index_inventory_movements_on_transaction" }
      t.references :item, null: false, foreign_key: true
      t.references :warehouse, null: false, foreign_key: true
      t.bigint :ledger_event_id, null: false
      t.integer :entry_line_no, null: false
      t.decimal :quantity, precision: 20, scale: 6, null: false
      t.bigint :inventory_value_minor, null: false
      t.decimal :balance_quantity_after, precision: 20, scale: 6, null: false
      t.bigint :balance_value_after_minor, null: false
      t.timestamps
    end
    add_index :inventory_movements, %i[tenant_id ledger_event_id entry_line_no], unique: true,
      name: "index_inventory_movements_on_ledger_identity"
    add_index :inventory_movements, %i[tenant_id item_id warehouse_id id],
      name: "index_inventory_movements_on_position"
    add_check_constraint :inventory_movements, "quantity <> 0",
      name: "inventory_movements_quantity_nonzero"
    add_check_constraint :inventory_movements, "inventory_value_minor <> 0",
      name: "inventory_movements_value_nonzero"
    add_check_constraint :inventory_movements, "balance_quantity_after >= 0",
      name: "inventory_movements_balance_quantity_nonnegative"
    add_check_constraint :inventory_movements, "balance_value_after_minor >= 0",
      name: "inventory_movements_balance_value_nonnegative"

    execute <<~SQL
      CREATE FUNCTION folio_inventory_evidence_immutable() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '% is immutable: % on row id=% rejected', TG_TABLE_NAME, TG_OP, OLD.id;
      END;
      $$;

      CREATE TRIGGER inventory_transactions_immutable
        BEFORE UPDATE OR DELETE ON inventory_transactions
        FOR EACH ROW EXECUTE FUNCTION folio_inventory_evidence_immutable();
      CREATE TRIGGER inventory_movements_immutable
        BEFORE UPDATE OR DELETE ON inventory_movements
        FOR EACH ROW EXECUTE FUNCTION folio_inventory_evidence_immutable();
    SQL

    execute <<~SQL.squish
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, capabilities.capability, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      CROSS JOIN (VALUES ('inventory.read'), ('inventory.manage'), ('inventory.post')) AS capabilities(capability)
      WHERE role_templates.code = 'accountant'
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = capabilities.capability
        )
    SQL
    execute <<~SQL.squish
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, 'inventory.read', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      WHERE role_templates.code IN ('ca_auditor', 'viewer')
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = 'inventory.read'
        )
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS inventory_movements_immutable ON inventory_movements;
      DROP TRIGGER IF EXISTS inventory_transactions_immutable ON inventory_transactions;
      DROP FUNCTION IF EXISTS folio_inventory_evidence_immutable();
    SQL
    drop_table :inventory_movements
    drop_table :inventory_transactions
    drop_table :stock_balances
    drop_table :warehouses
    remove_check_constraint :items, name: "items_inventory_profile_coherent"
    remove_columns :items, :inventory_class, :revision, :valuation_method, :inventory_account_code
  end
end
