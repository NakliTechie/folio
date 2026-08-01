# frozen_string_literal: true

# Stores the immutable INV-01 request plus the exact acknowledgement artifacts returned by
# an Invoice Registration Portal. Credentials and access tokens never belong in this table.
# Network adapters are deliberately configured outside the persistence model.
class CreateEinvoiceSubmissions < ActiveRecord::Migration[8.1]
  def change
    create_table :einvoice_submissions do |t|
      t.bigint :tenant_id, null: false
      t.references :document, null: false, foreign_key: true
      t.references :tax_registration, null: false, foreign_key: true
      t.string :provider, null: false, default: "offline_export"
      t.string :status, null: false, default: "prepared"
      t.string :schema_version, null: false, default: "1.1"
      t.string :request_id, null: false
      t.jsonb :payload, null: false
      t.string :payload_sha256, null: false, limit: 64
      t.integer :attempt_count, null: false, default: 0
      t.datetime :last_attempt_at
      t.string :irn, limit: 64
      t.string :ack_number
      t.datetime :acknowledged_at
      t.text :signed_invoice
      t.text :signed_qr_code
      t.string :signature_status, null: false, default: "not_checked"
      t.jsonb :provider_response
      t.string :provider_response_sha256, limit: 64
      t.string :error_code
      t.text :error_message
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :einvoice_submissions, [ :tenant_id, :document_id ], unique: true
    add_index :einvoice_submissions, [ :tenant_id, :request_id ], unique: true
    add_index :einvoice_submissions, [ :tenant_id, :irn ], unique: true,
      where: "irn IS NOT NULL"
    add_index :einvoice_submissions, [ :tenant_id, :status ]

    add_check_constraint :einvoice_submissions,
      "status IN ('prepared', 'submitting', 'acknowledged', 'rejected', 'indeterminate')",
      name: "einvoice_submissions_status_valid"
    add_check_constraint :einvoice_submissions,
      "signature_status IN ('not_checked', 'provider_verified', 'locally_verified', 'failed')",
      name: "einvoice_submissions_signature_status_valid"
    add_check_constraint :einvoice_submissions,
      "attempt_count >= 0",
      name: "einvoice_submissions_attempt_count_nonnegative"
    add_check_constraint :einvoice_submissions,
      <<~SQL.squish,
        (status <> 'acknowledged') OR
        (irn IS NOT NULL AND ack_number IS NOT NULL AND acknowledged_at IS NOT NULL AND
         signed_invoice IS NOT NULL AND signed_qr_code IS NOT NULL AND
         provider_response IS NOT NULL AND provider_response_sha256 IS NOT NULL)
      SQL
      name: "einvoice_submissions_ack_evidence_complete"
  end
end
