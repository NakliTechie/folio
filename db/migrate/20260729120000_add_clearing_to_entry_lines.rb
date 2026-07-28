# frozen_string_literal: true

# B3.3 — open-item clearing state (spec §5, decision D5).
#
# cleared_by_entry_id / cleared_on already exist (B3.1). This adds what partial vs residual
# clearing needs:
#  - cleared_amount_minor: how much of an open item a PARTIAL clearing has applied. The item
#    stays open with its original baseline_date (ageing PRESERVED); outstanding = original
#    amount − cleared_amount_minor.
#  - residual_of_line_id: a RESIDUAL clearing closes the original and opens a NEW item for the
#    balance with a fresh baseline_date (ageing RESET); this links that new item to its origin.
#  - clearing_reason: the reason code that joins clearing to disputes/write-offs/analytics.
# All additive and D15-safe (contribute nothing to the hash preimage).
class AddClearingToEntryLines < ActiveRecord::Migration[8.1]
  def change
    add_column :entry_lines, :cleared_amount_minor, :bigint, null: false, default: 0
    add_column :entry_lines, :residual_of_line_id, :bigint
    add_column :entry_lines, :clearing_reason, :string

    # Open items = open_item AND not yet fully cleared. The hot query for ageing/selection.
    add_index :entry_lines, [ :tenant_id, :assignment ],
      where: "open_item AND cleared_on IS NULL",
      name: "index_entry_lines_on_open_items"
  end
end
