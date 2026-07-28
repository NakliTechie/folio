# frozen_string_literal: true

# B3.5 — a thin account master (the seed of the real account master, Batch 5/6).
#
# The corpus trial-balance / account-type-totals reports output each account's stable
# identifier, name and type. Folio's entry_lines carry `account_code` (the stable code);
# this table maps that code to (name, type) so the reports can reproduce Bahi's golden
# output byte-for-byte. `code` holds Bahi's account_id (as a string) on import — Bahi has
# no separate code, so its integer id IS the stable identifier that appears in the report.
class CreateAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts do |t|
      t.bigint :tenant_id,    null: false
      t.string :code,         null: false   # stable account identifier
      t.string :name,         null: false
      t.string :account_type, null: false   # asset / liability / equity / income / expense
      t.timestamps
    end
    add_index :accounts, [ :tenant_id, :code ], unique: true
  end
end
