# frozen_string_literal: true

# M2.3 — RBAC as a MATRIX, not a role enum (spec §11 / D13, README §6). A role_template is a
# named role; role_permissions is the (role → capability) matrix; user_office_roles assigns a
# user a role. The v1 operating contract uses tenant-wide assignments; the nullable office
# reference is reserved for a future selected-office isolation contract. A
# posting_limit is an amount threshold the authority may post up to. Retrofitting an enum to a
# matrix would rewrite every authorization call site — so it is a matrix from M2.
class CreateRbacMatrix < ActiveRecord::Migration[8.1]
  def change
    create_table :role_templates do |t|
      t.bigint :tenant_id                       # nil = system preset; set = tenant-custom
      t.string :code, null: false               # owner / accountant / operator / ca_auditor / viewer
      t.string :name, null: false
      t.timestamps
    end
    add_index :role_templates, [ :tenant_id, :code ], unique: true

    create_table :role_permissions do |t|
      t.references :role_template, null: false, foreign_key: true
      t.string :capability, null: false         # e.g. documents.post, accounts.manage, "*"
      t.timestamps
    end
    add_index :role_permissions, [ :role_template_id, :capability ], unique: true

    create_table :posting_limits do |t|
      t.bigint :tenant_id,    null: false
      t.string :name,         null: false
      t.bigint :amount_minor, null: false        # max postable amount (minor units)
      t.timestamps
    end

    create_table :user_office_roles do |t|
      t.references :user, null: false, foreign_key: true
      t.bigint     :tenant_id, null: false
      t.bigint     :office_id                     # nil = tenant-wide
      t.references :role_template, null: false, foreign_key: true
      t.bigint     :posting_limit_id              # nil = unlimited
      t.timestamps
    end
    add_index :user_office_roles, [ :user_id, :tenant_id, :office_id ], unique: true,
      name: "index_user_office_roles_on_user_tenant_office"
  end
end
