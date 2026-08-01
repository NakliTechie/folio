# frozen_string_literal: true

# Batch 9: governed spot/closing rates, monetary-account designation, and durable revaluation
# runs. Historical postings carry their frozen transaction→functional conversion; closing runs
# append differences and never rewrite that historical basis.
class CreateForeignExchangeAccounting < ActiveRecord::Migration[8.1]
  def up
    add_column :accounts, :monetary, :boolean, null: false, default: false
    add_index :accounts, %i[tenant_id monetary], where: "monetary = TRUE"
    execute <<~SQL.squish
      UPDATE accounts
      SET monetary = TRUE
      WHERE code IN ('1000', '1010', '1190', '1200', '2000', '2100', '2110', '2200')
    SQL

    now = connection.quote(Time.current)
    execute <<~SQL.squish
      INSERT INTO accounts (tenant_id, code, name, account_type, active, monetary, created_at, updated_at)
      SELECT tenants.id, seeded.code, seeded.name, seeded.account_type, TRUE, FALSE, #{now}, #{now}
      FROM tenants
      CROSS JOIN (VALUES
        ('4100', 'Foreign Exchange Gains', 'income'),
        ('5200', 'Foreign Exchange Losses', 'expense')
      ) AS seeded(code, name, account_type)
      WHERE NOT EXISTS (
        SELECT 1 FROM accounts
        WHERE accounts.tenant_id = tenants.id AND accounts.code = seeded.code
      )
    SQL

    create_table :exchange_rates do |t|
      t.bigint :tenant_id, null: false
      t.string :from_currency, null: false, limit: 3
      t.string :to_currency, null: false, limit: 3
      t.date :effective_on, null: false
      t.decimal :rate, precision: 24, scale: 12, null: false
      t.string :rate_type, null: false, default: "spot"
      t.string :source, null: false
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :exchange_rates,
      %i[tenant_id from_currency to_currency rate_type effective_on], unique: true,
      name: "index_exchange_rates_on_governed_series"
    add_check_constraint :exchange_rates, "from_currency <> to_currency",
      name: "exchange_rates_distinct_currencies"
    add_check_constraint :exchange_rates, "rate > 0", name: "exchange_rates_positive"
    add_check_constraint :exchange_rates,
      "rate_type IN ('spot', 'closing', 'average')", name: "exchange_rates_type_valid"

    create_table :exchange_revaluation_runs do |t|
      t.bigint :tenant_id, null: false
      t.references :entity, null: false, foreign_key: true
      t.references :office, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :idempotency_key, null: false
      t.date :revaluation_date, null: false
      t.string :mode, null: false
      t.string :status, null: false, default: "pending"
      t.references :ledger_event
      t.jsonb :result, null: false, default: {}
      t.datetime :finished_at
      t.string :error_message
      t.timestamps
    end
    add_index :exchange_revaluation_runs, %i[tenant_id idempotency_key], unique: true,
      name: "index_exchange_revaluation_runs_on_idempotency"
    add_check_constraint :exchange_revaluation_runs,
      "mode IN ('simulate', 'post')", name: "exchange_revaluation_runs_mode_valid"
    add_check_constraint :exchange_revaluation_runs,
      "status IN ('pending', 'simulated', 'posted', 'failed')",
      name: "exchange_revaluation_runs_status_valid"

    create_table :exchange_revaluation_items do |t|
      t.bigint :tenant_id, null: false
      t.references :exchange_revaluation_run, null: false, foreign_key: true,
        index: { name: "index_exchange_revaluation_items_on_run" }
      t.string :account_code, null: false
      t.string :foreign_currency, null: false, limit: 3
      t.bigint :foreign_balance_minor, null: false
      t.bigint :carrying_functional_minor, null: false
      t.bigint :target_functional_minor, null: false
      t.bigint :difference_minor, null: false
      t.decimal :applied_rate, precision: 24, scale: 12, null: false
      t.references :exchange_rate, null: false, foreign_key: true
      t.timestamps
    end
    add_index :exchange_revaluation_items,
      %i[exchange_revaluation_run_id account_code foreign_currency], unique: true,
      name: "index_exchange_revaluation_items_on_position"

    execute <<~SQL.squish
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, capabilities.capability, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      CROSS JOIN (VALUES ('currency.read'), ('currency.manage'), ('currency.post')) AS capabilities(capability)
      WHERE role_templates.code = 'accountant'
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = capabilities.capability
        )
    SQL
    execute <<~SQL.squish
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, 'currency.read', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      WHERE role_templates.code IN ('ca_auditor', 'viewer')
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = 'currency.read'
        )
    SQL
  end

  def down
    drop_table :exchange_revaluation_items
    drop_table :exchange_revaluation_runs
    drop_table :exchange_rates
    remove_index :accounts, column: %i[tenant_id monetary]
    remove_column :accounts, :monetary
  end
end
