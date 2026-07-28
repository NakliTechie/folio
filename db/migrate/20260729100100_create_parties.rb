# frozen_string_literal: true

# B3.0 — the parties spine (spec §10, decision D12).
#
# Adopted now, before the vendor module, because Batch 3's first AP/AR line carries a
# party reference into an immutable event. Islands (customers/vendors tables) would mean
# a vendors→parties alias map forever — SAP's CVI, permanent migration debt for a system
# that never had to have it. party_number is stable and human-meaningful, because a
# .khata/Tally import arrives with codes, not surrogate uuids. customers and vendors
# become VIEWS over parties+party_roles (added in B3.1 alongside the subledger lines).
class CreateParties < ActiveRecord::Migration[8.1]
  def change
    create_table :parties do |t|
      t.bigint :tenant_id,    null: false
      t.string :party_number, null: false   # stable, human-meaningful — NOT only the surrogate id
      t.string :name,         null: false
      t.timestamps
    end
    add_index :parties, [ :tenant_id, :party_number ], unique: true

    create_table :party_roles do |t|
      t.bigint :party_id, null: false
      t.string :role,     null: false   # customer / vendor / employee / ... — many per party
      t.timestamps
    end
    add_index :party_roles, [ :party_id, :role ], unique: true
  end
end
