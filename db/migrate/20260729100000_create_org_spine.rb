# frozen_string_literal: true

# B3.0 — the organisational spine (spec §2, decision D3).
#
# entity (legal person) → office (place) → tax_registration (effective-dated).
# README §7 had office-carries-GSTIN, which is wrong in both directions: many offices
# share one GSTIN, and one office holds GSTIN + TAN + maybe ISD. Every Indian statutory
# return files per REGISTRATION, so tax_registrations is a first-class effective-dated
# master, not a column. offices is created here with entity_id from the start and no
# has_own_gstin — the superseded shape never exists.
class CreateOrgSpine < ActiveRecord::Migration[8.1]
  def change
    create_table :entities do |t|
      t.bigint  :tenant_id,           null: false
      t.string  :code,                null: false
      t.string  :legal_name,          null: false
      t.string  :functional_currency, null: false, limit: 3   # ISO 4217
      t.string  :fiscal_year_variant, null: false             # IN Apr-Mar; DE/UK/US/MY per profile
      t.string  :jurisdiction_profile, null: false            # IN / DE / UK / US / MY
      t.timestamps
    end
    add_index :entities, [ :tenant_id, :code ], unique: true

    create_table :offices do |t|
      t.bigint  :tenant_id, null: false
      t.bigint  :entity_id, null: false
      t.string  :code,      null: false
      t.string  :name,      null: false
      t.string  :default_place_of_supply
      t.timestamps
    end
    add_index :offices, [ :tenant_id, :code ], unique: true
    add_index :offices, :entity_id

    create_table :tax_registrations do |t|
      t.bigint  :tenant_id,  null: false
      t.bigint  :entity_id,  null: false
      t.string  :kind,       null: false   # GSTIN / TAN / ISD / VAT / EIN / SST
      t.string  :identifier, null: false   # validated per kind; GSTIN carries a mod-36 checksum
      t.string  :jurisdiction
      t.string  :state_code
      t.date    :valid_from                # effective-dated — a historical doc keeps the reg in force at posting
      t.date    :valid_to
      t.timestamps
    end
    add_index :tax_registrations, :entity_id
    add_index :tax_registrations, [ :tenant_id, :kind, :identifier ]
  end
end
