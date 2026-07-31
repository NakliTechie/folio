# frozen_string_literal: true

class BuildCashSettlements < ActiveRecord::Migration[8.1]
  def up
    create_table :document_allocations do |table|
      table.bigint :tenant_id, null: false
      table.references :document, null: false, foreign_key: true
      table.integer :line_no, null: false
      table.bigint :target_entry_line_id, null: false
      table.bigint :target_source_event_id, null: false
      table.integer :target_line_no, null: false
      table.bigint :amount_minor, null: false
      table.string :clearing_mode, null: false, default: "partial"
      table.jsonb :target_snapshot, null: false, default: {}
      table.bigint :target_clearing_event_id
      table.bigint :settlement_clearing_event_id
      table.timestamps
    end
    add_index :document_allocations, [ :document_id, :line_no ], unique: true
    add_index :document_allocations,
      [ :tenant_id, :target_source_event_id, :target_line_no ],
      name: "idx_document_allocations_stable_target"
    add_check_constraint :document_allocations, "amount_minor > 0",
      name: "chk_document_allocations_positive"
    add_check_constraint :document_allocations,
      "clearing_mode IN ('partial', 'residual')",
      name: "chk_document_allocations_mode"

    execute <<~SQL
      INSERT INTO document_types
        (tenant_id, code, label, posting_rule, number_prefix, version, active, created_at, updated_at)
      SELECT tenants.id, types.code, types.label, 'settlement', types.prefix, 1, TRUE,
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM tenants
      CROSS JOIN (
        VALUES ('RC', 'Customer Receipt', 'RC/'), ('PY', 'Vendor Payment', 'PY/')
      ) AS types(code, label, prefix)
      WHERE NOT EXISTS (
        SELECT 1 FROM document_types
        WHERE document_types.tenant_id = tenants.id AND document_types.code = types.code
      )
    SQL
  end

  def down
    execute "DELETE FROM document_types WHERE code IN ('RC', 'PY') AND posting_rule = 'settlement'"
    drop_table :document_allocations
  end
end
