# frozen_string_literal: true

# Event logs are authoritative append-only roots. Projection tables keep their event IDs and
# indexes, but deliberately do not own the log through foreign keys: the log's own DELETE/TRUNCATE
# guards must be the rejection point, and projections can always be rebuilt from stored events.
class RemoveEventLogProjectionForeignKeys < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :contracts, column: :created_domain_event_id
    remove_foreign_key :contract_allocation_runs, column: :created_domain_event_id
    remove_foreign_key :contract_schedules, column: :created_domain_event_id
    remove_foreign_key :contract_schedule_lines, column: :posted_ledger_event_id
    remove_foreign_key :contract_posting_run_items, column: :ledger_event_id
  end

  def down
    add_foreign_key :contracts, :domain_events, column: :created_domain_event_id
    add_foreign_key :contract_allocation_runs, :domain_events, column: :created_domain_event_id
    add_foreign_key :contract_schedules, :domain_events, column: :created_domain_event_id
    add_foreign_key :contract_schedule_lines, :ledger_events, column: :posted_ledger_event_id
    add_foreign_key :contract_posting_run_items, :ledger_events, column: :ledger_event_id
  end
end
