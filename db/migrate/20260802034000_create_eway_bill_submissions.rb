# frozen_string_literal: true

# An e-way bill for an e-invoice-enabled B2B tax invoice must be generated with, or by reference
# to, its IRN. This table freezes the EWB transport fragment included in Folio's INV-01 request and
# retains the separately governed EWB number/validity evidence returned by the provider.
class CreateEwayBillSubmissions < ActiveRecord::Migration[8.1]
  def up
    create_table :eway_bill_submissions do |t|
      t.bigint :tenant_id, null: false
      t.references :document, null: false, foreign_key: true
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.string :provider, null: false, default: "offline_export"
      t.string :status, null: false, default: "prepared"
      t.string :schema_version, null: false, default: "INV-01-EWB-1.1"
      t.string :request_id, null: false
      t.jsonb :payload, null: false
      t.string :payload_sha256, null: false, limit: 64
      t.string :eway_bill_number, limit: 12
      t.datetime :generated_at
      t.datetime :valid_until
      t.jsonb :provider_response
      t.string :provider_response_sha256, limit: 64
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :eway_bill_submissions, %i[tenant_id document_id], unique: true,
      name: "index_eway_bill_submissions_on_document"
    add_index :eway_bill_submissions, %i[tenant_id request_id], unique: true,
      name: "index_eway_bill_submissions_on_request"
    add_index :eway_bill_submissions, %i[tenant_id eway_bill_number], unique: true,
      where: "eway_bill_number IS NOT NULL", name: "index_eway_bill_submissions_on_number"
    add_index :eway_bill_submissions, %i[tenant_id status]
    add_check_constraint :eway_bill_submissions,
      "status IN ('prepared', 'generated')", name: "eway_bill_submissions_status_valid"
    add_check_constraint :eway_bill_submissions,
      <<~SQL.squish, name: "eway_bill_submissions_generation_complete"
        (status <> 'generated') OR
        (eway_bill_number IS NOT NULL AND generated_at IS NOT NULL AND valid_until IS NOT NULL AND
         provider_response IS NOT NULL AND provider_response_sha256 IS NOT NULL)
      SQL

    execute <<~SQL
      ALTER TABLE eway_bill_submissions ENABLE ROW LEVEL SECURITY;
      ALTER TABLE eway_bill_submissions FORCE ROW LEVEL SECURITY;
      CREATE POLICY folio_tenant_isolation ON eway_bill_submissions
        USING (tenant_id = NULLIF(current_setting('folio.tenant_id', true), '')::bigint)
        WITH CHECK (tenant_id = NULLIF(current_setting('folio.tenant_id', true), '')::bigint);
    SQL
  end

  def down
    drop_table :eway_bill_submissions
  end
end
