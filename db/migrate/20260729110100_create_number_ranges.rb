# frozen_string_literal: true

# B3.1 — statutory number ranges (spec §8, decision D8).
#
# NOT a Postgres sequence. A sequence does not roll back and is gap-prone by design; a
# statutory series must be gapless, so the next value is allocated inside the posting
# transaction with SELECT ... FOR UPDATE against the row for
# (tenant, entity, office, doc_type, fiscal_year). The allocation logic itself is exercised
# by PostEntry (B3.2) and the document layer (B3.4); this migration lays the row and its
# unique series key.
class CreateNumberRanges < ActiveRecord::Migration[8.1]
  def change
    create_table :number_ranges do |t|
      t.bigint  :tenant_id,   null: false
      t.bigint  :entity_id,   null: false
      t.bigint  :office_id,   null: false
      t.string  :doc_type,    null: false
      t.integer :fiscal_year, null: false
      t.bigint  :next_value,  null: false, default: 1   # the next number to hand out
      t.string  :prefix                                 # optional statutory prefix (e.g. "INV/25-26/")
      t.timestamps
    end
    add_index :number_ranges, [ :tenant_id, :entity_id, :office_id, :doc_type, :fiscal_year ],
      unique: true, name: "index_number_ranges_on_series_key"
  end
end
