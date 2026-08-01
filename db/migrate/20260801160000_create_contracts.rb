# frozen_string_literal: true

# Batch 6: the sell-side financial contract of record. Lifecycle facts live in domain_events;
# this table is the current, tenant-scoped projection used by the product and schedule engines.
class CreateContracts < ActiveRecord::Migration[8.1]
  def change
    create_table :contract_number_ranges do |t|
      t.bigint :tenant_id, null: false
      t.bigint :entity_id, null: false
      t.bigint :office_id, null: false
      t.integer :fiscal_year, null: false
      t.integer :next_value, null: false, default: 1
      t.timestamps
    end
    add_index :contract_number_ranges,
      %i[tenant_id entity_id office_id fiscal_year], unique: true,
      name: "index_contract_number_ranges_on_series"
    add_check_constraint :contract_number_ranges, "next_value > 0",
      name: "contract_number_ranges_next_value_positive"

    create_table :contracts do |t|
      t.bigint :tenant_id, null: false
      t.references :entity, null: false, foreign_key: true
      t.references :office, null: false, foreign_key: true
      t.references :party, null: false, foreign_key: true
      t.references :created_domain_event, null: false, foreign_key: { to_table: :domain_events }

      t.string :contract_number, null: false
      t.integer :fiscal_year, null: false
      t.string :title, null: false
      t.string :side, null: false, default: "sell"
      t.string :contract_type, null: false, default: "service_agreement"
      t.string :status, null: false, default: "draft"

      t.date :approval_date
      t.date :inception_date
      t.date :effective_date
      t.date :end_date
      t.date :enforceable_period_end
      t.date :closed_on
      t.string :term_type, null: false, default: "fixed"
      t.boolean :auto_renew, null: false, default: false
      t.integer :renewal_notice_days
      t.date :notice_deadline_date

      t.string :currency, null: false
      t.bigint :total_contract_value_minor, null: false
      t.string :accounting_treatment, null: false, default: "revenue_115"

      # India-specific evidence is recorded, never calculated authoritatively by Folio.
      t.string :jurisdiction, null: false, default: "IN"
      t.string :instrument_type
      t.date :execution_date
      t.string :stamp_status, null: false, default: "pending"
      t.string :stamp_state_code
      t.bigint :stamp_amount_minor
      t.string :stamp_certificate_reference
      t.date :stamp_date
      t.string :signature_status, null: false, default: "unsigned"
      t.datetime :signed_at
      t.boolean :registration_required, null: false, default: false
      t.string :registration_status, null: false, default: "not_required"
      t.string :registration_reference

      # Defaults inherited by future contract-linked sales documents.
      t.string :tds_section
      t.string :gst_treatment, null: false, default: "domestic_b2b"
      t.string :place_of_supply_state_code
      t.string :hsn_sac_code

      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :contracts, %i[tenant_id contract_number], unique: true
    add_index :contracts, %i[tenant_id status end_date]
    add_index :contracts, %i[tenant_id party_id status]
    add_index :contracts, %i[tenant_id notice_deadline_date],
      where: "status = 'active' AND notice_deadline_date IS NOT NULL"

    add_check_constraint :contracts, "side IN ('sell', 'buy', 'mutual', 'internal')",
      name: "contracts_side_valid"
    add_check_constraint :contracts, "status IN ('draft', 'signed', 'active', 'closed')",
      name: "contracts_status_valid"
    add_check_constraint :contracts,
      "term_type IN ('fixed', 'evergreen', 'auto_renew', 'perpetual', 'at_will')",
      name: "contracts_term_type_valid"
    add_check_constraint :contracts,
      "accounting_treatment IN ('none', 'revenue_115', 'prepaid', 'commitment')",
      name: "contracts_accounting_treatment_valid"
    add_check_constraint :contracts,
      "stamp_status IN ('not_applicable', 'pending', 'stamped', 'under_stamped')",
      name: "contracts_stamp_status_valid"
    add_check_constraint :contracts,
      "signature_status IN ('unsigned', 'partially_signed', 'signed')",
      name: "contracts_signature_status_valid"
    add_check_constraint :contracts,
      "registration_status IN ('not_required', 'pending', 'registered', 'overdue')",
      name: "contracts_registration_status_valid"
    add_check_constraint :contracts, "total_contract_value_minor >= 0",
      name: "contracts_total_value_nonnegative"
    add_check_constraint :contracts,
      "renewal_notice_days IS NULL OR renewal_notice_days >= 0",
      name: "contracts_renewal_notice_nonnegative"
    add_check_constraint :contracts,
      "stamp_amount_minor IS NULL OR stamp_amount_minor >= 0",
      name: "contracts_stamp_amount_nonnegative"
  end
end
