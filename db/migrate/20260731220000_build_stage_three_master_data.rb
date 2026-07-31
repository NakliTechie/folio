# frozen_string_literal: true

# Stage 3A: make the existing party and registration spines usable, add the product/service
# catalogue, and encode the tenant boundaries needed by the services-first GST vertical.
class BuildStageThreeMasterData < ActiveRecord::Migration[8.1]
  def change
    change_table :parties, bulk: true do |t|
      t.boolean :active, null: false, default: true
      t.string :email
      t.string :phone
      t.string :address_line1
      t.string :address_line2
      t.string :city
      t.string :postal_code
      t.string :state_code
      t.string :country_code, null: false, default: "IN", limit: 2
    end
    add_index :parties, [ :tenant_id, :active ]

    change_column_null :party_roles, :party_id, false
    add_foreign_key :party_roles, :parties

    create_table :party_tax_registrations do |t|
      t.bigint :tenant_id, null: false
      t.references :party, null: false, foreign_key: true
      t.string :kind, null: false, default: "GSTIN"
      t.string :identifier, null: false
      t.string :state_code
      t.date :valid_from, null: false
      t.date :valid_to
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :party_tax_registrations, [ :tenant_id, :kind, :identifier, :valid_from ], unique: true,
      name: "idx_party_tax_registrations_identity"
    add_check_constraint :party_tax_registrations,
      "valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from",
      name: "chk_party_tax_registration_dates"

    create_table :office_tax_registrations do |t|
      t.bigint :tenant_id, null: false
      t.references :office, null: false, foreign_key: true
      t.references :tax_registration, null: false, foreign_key: true
      t.timestamps
    end
    add_index :office_tax_registrations, [ :office_id, :tax_registration_id ], unique: true,
      name: "idx_office_tax_registrations_unique"
    add_index :office_tax_registrations, [ :tenant_id, :tax_registration_id ],
      name: "idx_office_tax_registrations_tenant_registration"

    add_column :tax_registrations, :active, :boolean, null: false, default: true
    change_column_null :tax_registrations, :valid_from, false
    remove_index :tax_registrations, [ :tenant_id, :kind, :identifier ]
    add_index :tax_registrations, [ :tenant_id, :kind, :identifier, :valid_from ], unique: true
    add_index :tax_registrations, [ :tenant_id, :active ]
    add_check_constraint :tax_registrations,
      "valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from",
      name: "chk_tax_registration_dates"

    create_table :items do |t|
      t.bigint :tenant_id, null: false
      t.string :code, null: false
      t.string :name, null: false
      t.string :item_type, null: false, default: "service"
      t.text :description
      t.string :hsn_sac_code, null: false
      t.string :unit_of_measure, null: false, default: "OTH"
      t.integer :tax_rate_basis_points, null: false, default: 0
      t.integer :cess_rate_basis_points, null: false, default: 0
      t.string :income_account_code, null: false
      t.string :expense_account_code, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :items, [ :tenant_id, :code ], unique: true
    add_index :items, [ :tenant_id, :active ]
    add_check_constraint :items, "item_type IN ('service', 'good')", name: "chk_items_type"
    add_check_constraint :items,
      "tax_rate_basis_points BETWEEN 0 AND 4000", name: "chk_items_tax_rate"
    add_check_constraint :items,
      "cess_rate_basis_points BETWEEN 0 AND 10000", name: "chk_items_cess_rate"
  end
end
