# frozen_string_literal: true

# B3.0 — ledgers (spec §1, decision D1, rank 1).
#
# The single reason open-source ERPs plateaued on multi-GAAP: no ledger discriminator
# from the start. For Folio it is not a luxury — every Indian company owning a fixed
# asset keeps two depreciation computations (Companies Act Schedule II per-asset vs
# Income-tax s.32 per block-of-assets), which are different UNITS OF ACCOUNT, not two
# rates. kind + underlying_ledger_id (extension ledgers) are specified now though
# unexposed in v1: one enum, one nullable FK, and the CA/Auditor role wants them almost
# immediately. Seeds exactly one ledger, PRIMARY.
class CreateLedgers < ActiveRecord::Migration[8.1]
  def change
    create_table :ledgers do |t|
      t.bigint  :tenant_id,            null: false
      t.string  :code,                 null: false
      t.string  :name,                 null: false
      t.string  :kind,                 null: false, default: "standard"  # standard / extension
      t.bigint  :underlying_ledger_id                                    # extension ledgers only
      t.boolean :posts_to_gl,          null: false, default: true        # false = statistical valuation
      t.date    :valid_from
      t.date    :valid_to
      t.timestamps
    end
    add_index :ledgers, [ :tenant_id, :code ], unique: true
  end
end
