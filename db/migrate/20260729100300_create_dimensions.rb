# frozen_string_literal: true

# B3.0 — the dimension registry (spec §3.1, decision D2, HYBRID per owner answer Q3).
#
# This AMENDS the 2026-07-27 "registry, NOT fixed columns" decision. The registry does
# NOT store values for committed dimensions — those are real typed columns on entry_lines
# (added in B3.1). It governs derivation, requiredness and validation. `committed` marks
# which dimensions are real columns (true) vs which live in entry_lines.extra jsonb
# (false, and never aggregated in a statutory report). required_rule carries the
# breakdown categories: a dimension required on IC accounts, forbidden on balance-sheet
# accounts, etc. — enforced at post time.
class CreateDimensions < ActiveRecord::Migration[8.1]
  def change
    create_table :dimensions do |t|
      t.bigint  :tenant_id,       null: false
      t.string  :code,            null: false   # COST_CENTER, PROFIT_CENTER, TAX_REGISTRATION, ...
      t.string  :label,           null: false
      t.string  :value_type,      null: false   # reference / text / enum
      t.boolean :committed,       null: false, default: false  # true = real column; false = lives in extra
      t.jsonb   :required_rule                  # required / optional / forbidden, per account or group
      t.jsonb   :derivation_rule                # how it is derived at post time when not supplied
      t.timestamps
    end
    add_index :dimensions, [ :tenant_id, :code ], unique: true
  end
end
