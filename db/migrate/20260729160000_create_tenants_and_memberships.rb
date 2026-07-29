# frozen_string_literal: true

# M2.2 — tenancy. A tenant (organisation) is the boundary every ledger row is already scoped
# to via tenant_id; this makes it a first-class record and links users to it through
# memberships. A membership is the ONLY thing that grants a user access to a tenant — the
# load-bearing isolation invariant is enforced by resolving Current.tenant strictly through a
# user's memberships. (Role lives on the membership from M2.3; here it is bare access.)
class CreateTenantsAndMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :tenants do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :functional_currency, null: false, default: "INR", limit: 3
      t.timestamps
    end
    add_index :tenants, :slug, unique: true

    create_table :memberships do |t|
      t.references :user,   null: false, foreign_key: true
      t.references :tenant, null: false, foreign_key: true
      t.timestamps
    end
    add_index :memberships, [ :user_id, :tenant_id ], unique: true
  end
end
