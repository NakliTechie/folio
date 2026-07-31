# frozen_string_literal: true

class BuildSettlementReallocation < ActiveRecord::Migration[8.1]
  def change
    change_table :document_allocations, bulk: true do |table|
      table.bigint :target_reset_event_id
      table.bigint :settlement_reset_event_id
    end

    create_table :settlement_reallocations do |table|
      table.bigint :tenant_id, null: false
      table.references :document_allocation, null: false, foreign_key: true, index: false
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
    add_index :settlement_reallocations, :document_allocation_id, unique: true
    add_index :settlement_reallocations,
      [ :tenant_id, :target_source_event_id, :target_line_no ],
      name: "idx_settlement_reallocations_stable_target"
    add_check_constraint :settlement_reallocations, "amount_minor > 0",
      name: "chk_settlement_reallocations_positive"
    add_check_constraint :settlement_reallocations,
      "clearing_mode IN ('partial', 'residual')",
      name: "chk_settlement_reallocations_mode"
  end
end
