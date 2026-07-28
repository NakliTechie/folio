# frozen_string_literal: true

# B3.1 — journal_entry_line_amounts (spec §4, decision D4).
#
# CHILD TABLE (owner answer Q4), reversed from a fixed currency triple: multi-currency
# flexibility is coming, and a fixed triple could not survive a fourth currency without a
# migration + full replay. One row per (line, slot). Cost: a join per line read.
#
# The five non-negotiables:
#   1. minor_unit_exponent is per ISO 4217 (JPY/KRW 0, most 2, some 3, CLF 4) — NOT ×100.
#   2. the group slot stores its translation BASIS (document/posting/translation date).
#   3. amount_minor is SIGNED — no debit/credit pair (that lives only in the .khata export
#      projection); the DB must not carry debit/credit columns here.
#   4. a designated rounding account receives rounding differences — a posting-engine +
#      account-setting concern realised in B3.2, not a column here.
#   5. value_date is on entry_lines, not here.
class CreateJournalEntryLineAmounts < ActiveRecord::Migration[8.1]
  def change
    create_table :journal_entry_line_amounts do |t|
      t.bigint   :tenant_id,     null: false
      t.bigint   :entry_line_id, null: false
      t.string   :slot_role,     null: false                   # transaction / functional / group
      t.string   :currency,      null: false, limit: 3         # ISO 4217
      t.integer  :minor_unit_exponent, null: false, limit: 2    # smallint; per ISO 4217, NOT hardcoded 2
      t.bigint   :amount_minor,  null: false                   # SIGNED minor units, not a Dr/Cr pair
      t.decimal  :rate, precision: 20, scale: 10               # nullable — present only when translated
      t.date     :rate_date
      t.string   :rate_source
      t.string   :rate_basis                                   # document_date / posting_date / translation_date
      t.timestamps
    end
    add_index :journal_entry_line_amounts, :entry_line_id
    add_index :journal_entry_line_amounts, [ :entry_line_id, :slot_role ], unique: true,
      name: "index_jela_on_line_and_slot"
  end
end
