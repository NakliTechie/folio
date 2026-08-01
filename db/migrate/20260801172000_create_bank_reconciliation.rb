# frozen_string_literal: true

# Batch 9: bank statement evidence and durable matching. A match stores the immutable ledger-event
# id + line number, never only the disposable entry-line projection id, so rebuild cannot orphan it.
class CreateBankReconciliation < ActiveRecord::Migration[8.1]
  def up
    create_table :bank_statement_imports do |t|
      t.bigint :tenant_id, null: false
      t.references :entity, null: false, foreign_key: true
      t.references :office, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.bigint :created_domain_event_id, null: false
      t.bigint :reconciled_domain_event_id
      t.string :bank_account_code, null: false
      t.string :currency, null: false, limit: 3
      t.string :file_name, null: false
      t.string :source_sha256, null: false
      t.date :statement_from, null: false
      t.date :statement_to, null: false
      t.bigint :opening_balance_minor, null: false
      t.bigint :closing_balance_minor, null: false
      t.integer :row_count, null: false
      t.string :status, null: false, default: "imported"
      t.datetime :reconciled_at
      t.timestamps
    end
    add_index :bank_statement_imports,
      %i[tenant_id bank_account_code source_sha256], unique: true,
      name: "index_bank_statement_imports_on_source"
    add_index :bank_statement_imports,
      %i[tenant_id bank_account_code statement_to],
      name: "index_bank_statement_imports_on_account_period"
    add_check_constraint :bank_statement_imports,
      "statement_to >= statement_from", name: "bank_statement_imports_period_valid"
    add_check_constraint :bank_statement_imports,
      "row_count > 0", name: "bank_statement_imports_row_count_positive"
    add_check_constraint :bank_statement_imports,
      "status IN ('imported', 'reconciled')", name: "bank_statement_imports_status_valid"
    add_check_constraint :bank_statement_imports,
      <<~SQL.squish, name: "bank_statement_imports_reconciliation_coherent"
        (status = 'imported' AND reconciled_domain_event_id IS NULL AND reconciled_at IS NULL)
        OR
        (status = 'reconciled' AND reconciled_domain_event_id IS NOT NULL AND reconciled_at IS NOT NULL)
      SQL

    create_table :bank_statement_lines do |t|
      t.bigint :tenant_id, null: false
      t.references :bank_statement_import, null: false, foreign_key: true,
        index: { name: "index_bank_statement_lines_on_import" }
      t.integer :line_no, null: false
      t.date :booking_date, null: false
      t.date :value_date, null: false
      t.bigint :amount_minor, null: false
      t.string :currency, null: false, limit: 3
      t.string :bank_reference
      t.string :description, null: false
      t.string :counterparty
      t.string :status, null: false, default: "unmatched"
      t.string :match_method
      t.bigint :matched_ledger_event_id
      t.integer :matched_entry_line_no
      t.references :matched_by, foreign_key: { to_table: :users }
      t.datetime :matched_at
      t.string :ignore_reason
      t.timestamps
    end
    add_index :bank_statement_lines,
      %i[bank_statement_import_id line_no], unique: true,
      name: "index_bank_statement_lines_on_line_no"
    add_index :bank_statement_lines,
      %i[tenant_id matched_ledger_event_id matched_entry_line_no], unique: true,
      where: "matched_ledger_event_id IS NOT NULL",
      name: "index_bank_statement_lines_on_ledger_identity"
    add_index :bank_statement_lines,
      %i[tenant_id status booking_date], name: "index_bank_statement_lines_for_matching"
    add_check_constraint :bank_statement_lines,
      "line_no > 0", name: "bank_statement_lines_number_positive"
    add_check_constraint :bank_statement_lines,
      "amount_minor <> 0", name: "bank_statement_lines_amount_nonzero"
    add_check_constraint :bank_statement_lines,
      "status IN ('unmatched', 'matched', 'ignored')", name: "bank_statement_lines_status_valid"
    add_check_constraint :bank_statement_lines,
      "match_method IS NULL OR match_method IN ('exact', 'manual')",
      name: "bank_statement_lines_match_method_valid"
    add_check_constraint :bank_statement_lines,
      "matched_entry_line_no IS NULL OR matched_entry_line_no > 0",
      name: "bank_statement_lines_matched_line_positive"
    add_check_constraint :bank_statement_lines,
      <<~SQL.squish, name: "bank_statement_lines_resolution_coherent"
        (status = 'unmatched' AND match_method IS NULL AND matched_ledger_event_id IS NULL
          AND matched_entry_line_no IS NULL AND matched_by_id IS NULL AND matched_at IS NULL
          AND ignore_reason IS NULL)
        OR
        (status = 'matched' AND match_method IS NOT NULL AND matched_ledger_event_id IS NOT NULL
          AND matched_entry_line_no IS NOT NULL AND matched_by_id IS NOT NULL AND matched_at IS NOT NULL
          AND ignore_reason IS NULL)
        OR
        (status = 'ignored' AND match_method IS NULL AND matched_ledger_event_id IS NULL
          AND matched_entry_line_no IS NULL AND matched_by_id IS NULL AND matched_at IS NULL
          AND ignore_reason IS NOT NULL)
      SQL

    execute <<~SQL.squish
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, capabilities.capability, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      CROSS JOIN (VALUES ('banking.read'), ('banking.manage'), ('banking.reconcile')) AS capabilities(capability)
      WHERE role_templates.code = 'accountant'
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = capabilities.capability
        )
    SQL
    execute <<~SQL.squish
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, 'banking.read', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      WHERE role_templates.code IN ('ca_auditor', 'viewer')
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = 'banking.read'
        )
    SQL
  end

  def down
    drop_table :bank_statement_lines
    drop_table :bank_statement_imports
  end
end
