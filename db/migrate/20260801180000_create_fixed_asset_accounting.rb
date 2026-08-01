# frozen_string_literal: true

# Batch 9: a fixed-asset subledger with component identity, parallel book/tax
# valuations, immutable value movements, and rebuildable carrying amounts.
class CreateFixedAssetAccounting < ActiveRecord::Migration[8.1]
  def up
    now = connection.quote(Time.current)
    execute <<~SQL.squish
      INSERT INTO accounts (tenant_id, code, name, account_type, active, monetary, created_at, updated_at)
      SELECT tenants.id, seeded.code, seeded.name, seeded.account_type, TRUE, FALSE, #{now}, #{now}
      FROM tenants
      CROSS JOIN (VALUES
        ('1400', 'Property, Plant and Equipment', 'asset'),
        ('1410', 'Accumulated Depreciation', 'asset'),
        ('5150', 'Depreciation Expense', 'expense'),
        ('4200', 'Gain on Asset Disposal', 'income'),
        ('5155', 'Loss on Asset Disposal', 'expense')
      ) AS seeded(code, name, account_type)
      WHERE NOT EXISTS (
        SELECT 1 FROM accounts
        WHERE accounts.tenant_id = tenants.id AND accounts.code = seeded.code
      )
    SQL

    create_table :asset_classes do |t|
      t.bigint :tenant_id, null: false
      t.string :code, null: false
      t.string :name, null: false
      t.string :apc_account_code, null: false
      t.string :accumulated_depreciation_account_code, null: false
      t.string :depreciation_expense_account_code, null: false
      t.string :gain_account_code, null: false
      t.string :loss_account_code, null: false
      t.integer :default_useful_life_months, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :asset_classes, %i[tenant_id code], unique: true
    add_check_constraint :asset_classes, "default_useful_life_months > 0",
      name: "asset_classes_useful_life_positive"

    execute <<~SQL.squish
      INSERT INTO asset_classes
        (tenant_id, code, name, apc_account_code, accumulated_depreciation_account_code,
         depreciation_expense_account_code, gain_account_code, loss_account_code,
         default_useful_life_months, active, created_at, updated_at)
      SELECT tenants.id, 'PPE', 'Property, plant and equipment', '1400', '1410', '5150',
             '4200', '5155', 60, TRUE, #{now}, #{now}
      FROM tenants
    SQL

    create_table :fixed_assets do |t|
      t.bigint :tenant_id, null: false
      t.references :entity, null: false, foreign_key: true
      t.references :office, null: false, foreign_key: true
      t.references :asset_class, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      # Event logs are append-only roots. Keep the indexed identity without a reverse FK so
      # their own DELETE/TRUNCATE guards remain the authoritative rejection point.
      t.references :created_domain_event, null: false
      t.string :asset_number, null: false
      t.string :component_number, null: false, default: "0000"
      t.string :name, null: false
      t.text :description
      t.string :status, null: false, default: "draft"
      t.date :acquired_on
      t.date :capitalization_date, null: false
      t.decimal :quantity, precision: 20, scale: 6, null: false, default: 1
      t.string :unit_of_measure, null: false, default: "EA"
      t.string :serial_number
      t.string :inventory_number
      t.string :manufacturer
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :fixed_assets, %i[tenant_id asset_number component_number], unique: true,
      name: "index_fixed_assets_on_component_identity"
    add_index :fixed_assets, %i[tenant_id status capitalization_date]
    add_check_constraint :fixed_assets, "status IN ('draft', 'active', 'retired')",
      name: "fixed_assets_status_valid"
    add_check_constraint :fixed_assets, "quantity > 0", name: "fixed_assets_quantity_positive"

    create_table :asset_valuation_terms do |t|
      t.bigint :tenant_id, null: false
      t.references :fixed_asset, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :created_domain_event, null: false
      t.string :valuation_code, null: false
      t.boolean :posts_to_ledger, null: false, default: false
      t.string :depreciation_method, null: false, default: "straight_line"
      t.integer :useful_life_months, null: false
      t.bigint :residual_value_minor, null: false, default: 0
      t.date :depreciation_start_date, null: false
      t.date :valid_from, null: false
      t.date :valid_to
      t.timestamps
    end
    add_index :asset_valuation_terms, %i[tenant_id fixed_asset_id valuation_code valid_from],
      unique: true, name: "index_asset_terms_on_effective_identity"
    add_check_constraint :asset_valuation_terms, "valuation_code IN ('BOOK', 'TAX_IT')",
      name: "asset_valuation_terms_code_valid"
    add_check_constraint :asset_valuation_terms, "depreciation_method = 'straight_line'",
      name: "asset_valuation_terms_method_valid"
    add_check_constraint :asset_valuation_terms, "useful_life_months > 0",
      name: "asset_valuation_terms_life_positive"
    add_check_constraint :asset_valuation_terms, "residual_value_minor >= 0",
      name: "asset_valuation_terms_residual_nonnegative"
    add_check_constraint :asset_valuation_terms, "valid_to IS NULL OR valid_to >= valid_from",
      name: "asset_valuation_terms_range_valid"
    add_index :asset_valuation_terms, %i[fixed_asset_id valuation_code], unique: true,
      where: "valid_to IS NULL", name: "index_asset_terms_on_one_current_term"

    create_table :asset_valuations do |t|
      t.bigint :tenant_id, null: false
      t.references :fixed_asset, null: false, foreign_key: true
      t.references :asset_valuation_term, null: false, foreign_key: true
      t.string :valuation_code, null: false
      t.boolean :posts_to_ledger, null: false
      t.bigint :gross_block_minor, null: false, default: 0
      t.bigint :accumulated_depreciation_minor, null: false, default: 0
      t.date :depreciation_posted_through
      t.bigint :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :asset_valuations, %i[tenant_id fixed_asset_id valuation_code], unique: true,
      name: "index_asset_valuations_on_view"
    add_check_constraint :asset_valuations, "valuation_code IN ('BOOK', 'TAX_IT')",
      name: "asset_valuations_code_valid"
    add_check_constraint :asset_valuations,
      "gross_block_minor >= 0 AND accumulated_depreciation_minor >= 0 " \
      "AND accumulated_depreciation_minor <= gross_block_minor",
      name: "asset_valuations_values_coherent"

    create_table :depreciation_runs do |t|
      t.bigint :tenant_id, null: false
      t.references :entity, null: false, foreign_key: true
      t.references :office, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :idempotency_key, null: false
      t.string :request_sha256, null: false
      t.string :mode, null: false
      t.string :status, null: false
      t.date :through_date, null: false
      t.date :posting_date, null: false
      t.jsonb :result, null: false, default: {}
      t.timestamps
    end
    add_index :depreciation_runs, %i[tenant_id idempotency_key], unique: true
    add_check_constraint :depreciation_runs, "mode IN ('simulate', 'post')",
      name: "depreciation_runs_mode_valid"
    add_check_constraint :depreciation_runs, "status IN ('simulated', 'posted')",
      name: "depreciation_runs_status_valid"

    create_table :asset_transactions do |t|
      t.bigint :tenant_id, null: false
      t.references :fixed_asset, null: false, foreign_key: true
      t.references :asset_valuation, null: false, foreign_key: true
      t.references :depreciation_run, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.bigint :ledger_event_id
      t.string :idempotency_key, null: false
      t.string :transaction_type, null: false
      t.string :valuation_code, null: false
      t.date :asset_value_date, null: false
      t.date :posting_date, null: false
      t.bigint :amount_minor, null: false
      t.jsonb :details, null: false, default: {}
      t.timestamps
    end
    add_index :asset_transactions, %i[tenant_id idempotency_key valuation_code], unique: true,
      name: "index_asset_transactions_on_idempotency"
    add_index :asset_transactions, %i[tenant_id fixed_asset_id valuation_code asset_value_date],
      name: "index_asset_transactions_on_history"
    add_check_constraint :asset_transactions, "transaction_type IN ('acquisition', 'depreciation')",
      name: "asset_transactions_type_valid"
    add_check_constraint :asset_transactions, "valuation_code IN ('BOOK', 'TAX_IT')",
      name: "asset_transactions_code_valid"
    add_check_constraint :asset_transactions, "amount_minor > 0",
      name: "asset_transactions_amount_positive"

    add_reference :entry_lines, :fixed_asset, foreign_key: true
    add_column :entry_lines, :asset_value_date, :date

    execute <<~SQL
      CREATE FUNCTION folio_asset_evidence_immutable() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '% is immutable: % on row id=% rejected', TG_TABLE_NAME, TG_OP, OLD.id;
      END;
      $$;

      CREATE TRIGGER asset_transactions_immutable
        BEFORE UPDATE OR DELETE ON asset_transactions
        FOR EACH ROW EXECUTE FUNCTION folio_asset_evidence_immutable();
    SQL

    execute <<~SQL.squish
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, capabilities.capability, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      CROSS JOIN (VALUES ('assets.read'), ('assets.manage'), ('assets.post')) AS capabilities(capability)
      WHERE role_templates.code = 'accountant'
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = capabilities.capability
        )
    SQL
    execute <<~SQL.squish
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, 'assets.read', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      WHERE role_templates.code IN ('ca_auditor', 'viewer')
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = 'assets.read'
        )
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS asset_transactions_immutable ON asset_transactions;
      DROP FUNCTION IF EXISTS folio_asset_evidence_immutable();
    SQL
    remove_column :entry_lines, :asset_value_date
    remove_reference :entry_lines, :fixed_asset
    drop_table :asset_transactions
    drop_table :depreciation_runs
    drop_table :asset_valuations
    drop_table :asset_valuation_terms
    drop_table :fixed_assets
    drop_table :asset_classes
  end
end
