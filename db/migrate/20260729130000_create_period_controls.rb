# frozen_string_literal: true

# B3.4 — period control (spec §6, decision D6). NOT a boolean.
#
# The minimum shape is (entity, ledger, account_class, fiscal_year, period_no) → {open,
# restricted, closed}, plus a capability name that `restricted` requires. Real closes shut
# AP and AR while G/L stays open for adjustments (hence account_class), and a local-GAAP
# ledger closes weeks after the IFRS one (hence ledger). `domain` carries the SEPARATE tax
# lock and inventory period the spec calls for — a period can be closed for posting yet open
# for a tax amendment. `account_class = "ALL"` is the wildcard.
#
# Enforced in the ENGINE, on the single posting entry point (PostEntry.post!), never in the
# UI — and only at post time. Replaying a historical event never re-checks period control.
class CreatePeriodControls < ActiveRecord::Migration[8.1]
  def change
    create_table :period_controls do |t|
      t.bigint  :tenant_id,     null: false
      t.bigint  :entity_id,     null: false
      t.bigint  :ledger_id,     null: false
      t.string  :account_class, null: false, default: "ALL"     # AP / AR / GL / ... or ALL
      t.integer :fiscal_year,   null: false
      t.integer :period_no,     null: false                     # {0} ∪ [1..12] ∪ [13..16]
      t.string  :state,         null: false, default: "open"    # open / restricted / closed
      t.string  :capability                                     # required when state = restricted
      t.string  :domain,        null: false, default: "posting" # posting / tax / inventory
      t.timestamps
    end
    add_index :period_controls,
      [ :tenant_id, :entity_id, :ledger_id, :fiscal_year, :period_no, :account_class, :domain ],
      unique: true, name: "index_period_controls_on_scope"

    execute <<~SQL
      ALTER TABLE period_controls ADD CONSTRAINT chk_period_controls_period_no
        CHECK (period_no >= 0 AND period_no <= 16)
    SQL
  end
end
