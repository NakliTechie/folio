# frozen_string_literal: true

# A line number is stable only inside a ledger. Qualify settlement targets and the
# projection lookup index accordingly; event payloads add ledgerId separately while
# retaining a legacy replay path for the existing single-ledger event corpus.
class QualifyClearingTargetsByLedger < ActiveRecord::Migration[8.1]
  def up
    add_column :document_allocations, :target_ledger_id, :bigint
    add_column :settlement_reallocations, :target_ledger_id, :bigint

    backfill_target_ledgers(:document_allocations)
    backfill_target_ledgers(:settlement_reallocations)

    change_column_null :document_allocations, :target_ledger_id, false
    change_column_null :settlement_reallocations, :target_ledger_id, false

    remove_index :entry_lines, name: "index_entry_lines_on_source_line_key"
    add_index :entry_lines, [ :tenant_id, :source_event_id, :ledger_id, :line_no ],
      name: "index_entry_lines_on_source_ledger_line_key"

    remove_index :document_allocations, name: "idx_document_allocations_stable_target"
    add_index :document_allocations,
      [ :tenant_id, :target_source_event_id, :target_ledger_id, :target_line_no ],
      name: "idx_document_allocations_stable_target"

    remove_index :settlement_reallocations, name: "idx_settlement_reallocations_stable_target"
    add_index :settlement_reallocations,
      [ :tenant_id, :target_source_event_id, :target_ledger_id, :target_line_no ],
      name: "idx_settlement_reallocations_stable_target"
  end

  def down
    remove_index :settlement_reallocations, name: "idx_settlement_reallocations_stable_target"
    add_index :settlement_reallocations,
      [ :tenant_id, :target_source_event_id, :target_line_no ],
      name: "idx_settlement_reallocations_stable_target"

    remove_index :document_allocations, name: "idx_document_allocations_stable_target"
    add_index :document_allocations,
      [ :tenant_id, :target_source_event_id, :target_line_no ],
      name: "idx_document_allocations_stable_target"

    remove_index :entry_lines, name: "index_entry_lines_on_source_ledger_line_key"
    add_index :entry_lines, [ :tenant_id, :source_event_id, :line_no ],
      name: "index_entry_lines_on_source_line_key"

    remove_column :settlement_reallocations, :target_ledger_id
    remove_column :document_allocations, :target_ledger_id
  end

  private

  def backfill_target_ledgers(table)
    execute <<~SQL
      UPDATE #{quote_table_name(table)} AS targets
      SET target_ledger_id = (
        SELECT entry_lines.ledger_id
        FROM entry_lines
        WHERE entry_lines.tenant_id = targets.tenant_id
          AND entry_lines.source_event_id = targets.target_source_event_id
          AND entry_lines.line_no = targets.target_line_no
        ORDER BY entry_lines.id
        LIMIT 1
      )
    SQL
  end
end
