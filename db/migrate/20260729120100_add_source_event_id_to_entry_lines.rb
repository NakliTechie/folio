# frozen_string_literal: true

# B3.3 — a stable per-line identity for clearing to target (spec §8: line_no "referenced by
# clearing forever"; decision D5).
#
# A clearing event must name the EXACT open item it clears, in a way that survives a full
# projection rebuild. Projection ids do not (they are reassigned on rebuild); the
# ledger_event that CREATED a line does — ledger_events is never rebuilt. So each entry_line
# records source_event_id (the creating event), and (source_event_id, line_no) is the stable
# line key a clearing references. Without it, clearing could only find items by `assignment`,
# which silently mis-targets a residual or a reused assignment.
class AddSourceEventIdToEntryLines < ActiveRecord::Migration[8.1]
  def change
    add_column :entry_lines, :source_event_id, :bigint
    add_index :entry_lines, [ :tenant_id, :source_event_id, :line_no ],
      name: "index_entry_lines_on_source_line_key"
  end
end
