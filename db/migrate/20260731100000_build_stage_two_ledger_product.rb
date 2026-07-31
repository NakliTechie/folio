# frozen_string_literal: true

# Finishes the Stage 2 accounting foundation: accounts gain a non-destructive lifecycle,
# opening balances become a real document type, and statutory statements read through a
# versioned presentation hierarchy instead of guessing presentation from account_type.
class BuildStageTwoLedgerProduct < ActiveRecord::Migration[8.1]
  def up
    add_column :accounts, :active, :boolean, null: false, default: true
    add_index :accounts, [ :tenant_id, :active ]

    create_table :financial_statement_versions do |t|
      t.bigint :tenant_id, null: false
      t.string :name, null: false
      t.integer :version, null: false
      t.date :effective_from, null: false
      t.date :effective_to
      t.string :status, null: false, default: "active"
      t.timestamps
    end
    add_index :financial_statement_versions, [ :tenant_id, :version ], unique: true,
      name: "idx_statement_versions_tenant_version"
    add_index :financial_statement_versions, [ :tenant_id, :effective_from ],
      name: "idx_statement_versions_effective"
    add_check_constraint :financial_statement_versions,
      "status IN ('draft', 'active', 'retired')", name: "chk_statement_versions_status"
    add_check_constraint :financial_statement_versions,
      "effective_to IS NULL OR effective_to >= effective_from", name: "chk_statement_versions_dates"

    create_table :financial_statement_sections do |t|
      t.bigint :tenant_id, null: false
      t.references :financial_statement_version, null: false, foreign_key: true,
        index: { name: "idx_statement_sections_version" }
      t.references :parent, foreign_key: { to_table: :financial_statement_sections },
        index: { name: "idx_statement_sections_parent" }
      t.string :statement_type, null: false
      t.string :code, null: false
      t.string :label, null: false
      t.string :normal_balance, null: false
      t.integer :sort_order, null: false
      t.timestamps
    end
    add_index :financial_statement_sections,
      [ :financial_statement_version_id, :code ], unique: true,
      name: "idx_statement_sections_version_code"
    add_index :financial_statement_sections,
      [ :financial_statement_version_id, :statement_type, :sort_order ],
      name: "idx_statement_sections_order"
    add_check_constraint :financial_statement_sections,
      "statement_type IN ('balance_sheet', 'profit_and_loss')", name: "chk_statement_sections_type"
    add_check_constraint :financial_statement_sections,
      "normal_balance IN ('debit', 'credit')", name: "chk_statement_sections_normal_balance"

    create_table :financial_statement_assignments do |t|
      t.bigint :tenant_id, null: false
      t.references :financial_statement_version, null: false, foreign_key: true,
        index: { name: "idx_statement_assignments_version" }
      t.references :financial_statement_section, null: false, foreign_key: true,
        index: { name: "idx_statement_assignments_section" }
      t.references :account, null: false, foreign_key: true
      t.timestamps
    end
    add_index :financial_statement_assignments,
      [ :financial_statement_version_id, :account_id ], unique: true,
      name: "idx_statement_assignments_version_account"
    add_index :financial_statement_assignments, [ :tenant_id, :account_id ],
      name: "idx_statement_assignments_tenant_account"

    seed_opening_balance_document_types
    seed_default_statement_layouts
  end

  def down
    drop_table :financial_statement_assignments
    drop_table :financial_statement_sections
    drop_table :financial_statement_versions
    remove_index :accounts, [ :tenant_id, :active ]
    remove_column :accounts, :active
    execute "DELETE FROM document_types WHERE code = 'OB' AND posting_rule = 'opening_balance'"
  end

  private

  def seed_opening_balance_document_types
    execute <<~SQL
      INSERT INTO document_types
        (tenant_id, code, label, posting_rule, number_prefix, version, active, created_at, updated_at)
      SELECT tenants.id, 'OB', 'Opening Balance', 'opening_balance', 'OB/', 1, TRUE,
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM tenants
      WHERE NOT EXISTS (
        SELECT 1 FROM document_types
        WHERE document_types.tenant_id = tenants.id AND document_types.code = 'OB'
      )
    SQL
  end

  def seed_default_statement_layouts
    execute <<~SQL
      INSERT INTO financial_statement_versions
        (tenant_id, name, version, effective_from, status, created_at, updated_at)
      SELECT tenants.id, 'Default financial statements', 1, DATE '1900-01-01', 'active',
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM tenants
    SQL

    execute <<~SQL
      INSERT INTO financial_statement_sections
        (tenant_id, financial_statement_version_id, statement_type, code, label,
         normal_balance, sort_order, created_at, updated_at)
      SELECT versions.tenant_id, versions.id, definitions.statement_type,
             definitions.code, definitions.label, definitions.normal_balance,
             definitions.sort_order, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM financial_statement_versions versions
      CROSS JOIN (VALUES
        ('balance_sheet', 'assets', 'Assets', 'debit', 100),
        ('balance_sheet', 'current_assets', 'Current assets', 'debit', 110),
        ('balance_sheet', 'non_current_assets', 'Non-current assets', 'debit', 120),
        ('balance_sheet', 'equity_liabilities', 'Equity and liabilities', 'credit', 200),
        ('balance_sheet', 'equity', 'Equity', 'credit', 210),
        ('balance_sheet', 'current_liabilities', 'Current liabilities', 'credit', 220),
        ('balance_sheet', 'non_current_liabilities', 'Non-current liabilities', 'credit', 230),
        ('profit_and_loss', 'income', 'Income', 'credit', 100),
        ('profit_and_loss', 'operating_revenue', 'Operating revenue', 'credit', 110),
        ('profit_and_loss', 'other_income', 'Other income', 'credit', 120),
        ('profit_and_loss', 'expenses', 'Expenses', 'debit', 200),
        ('profit_and_loss', 'operating_expenses', 'Operating expenses', 'debit', 210),
        ('profit_and_loss', 'finance_costs', 'Finance costs', 'debit', 220),
        ('profit_and_loss', 'tax_expense', 'Tax expense', 'debit', 230)
      ) AS definitions(statement_type, code, label, normal_balance, sort_order)
    SQL

    execute <<~SQL
      UPDATE financial_statement_sections AS child
      SET parent_id = parent.id
      FROM financial_statement_sections AS parent
      WHERE child.financial_statement_version_id = parent.financial_statement_version_id
        AND parent.code = CASE child.code
          WHEN 'current_assets' THEN 'assets'
          WHEN 'non_current_assets' THEN 'assets'
          WHEN 'equity' THEN 'equity_liabilities'
          WHEN 'current_liabilities' THEN 'equity_liabilities'
          WHEN 'non_current_liabilities' THEN 'equity_liabilities'
          WHEN 'operating_revenue' THEN 'income'
          WHEN 'other_income' THEN 'income'
          WHEN 'operating_expenses' THEN 'expenses'
          WHEN 'finance_costs' THEN 'expenses'
          WHEN 'tax_expense' THEN 'expenses'
        END
    SQL

    execute <<~SQL
      INSERT INTO financial_statement_assignments
        (tenant_id, financial_statement_version_id, financial_statement_section_id,
         account_id, created_at, updated_at)
      SELECT accounts.tenant_id, versions.id, sections.id, accounts.id,
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM accounts
      JOIN financial_statement_versions versions
        ON versions.tenant_id = accounts.tenant_id AND versions.version = 1
      JOIN financial_statement_sections sections
        ON sections.financial_statement_version_id = versions.id
       AND sections.code = CASE accounts.account_type
         WHEN 'asset' THEN 'current_assets'
         WHEN 'liability' THEN 'current_liabilities'
         WHEN 'equity' THEN 'equity'
         WHEN 'income' THEN 'operating_revenue'
         WHEN 'expense' THEN 'operating_expenses'
       END
    SQL
  end
end
