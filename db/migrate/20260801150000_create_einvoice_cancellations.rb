# frozen_string_literal: true

class CreateEinvoiceCancellations < ActiveRecord::Migration[8.1]
  def change
    create_table :einvoice_cancellations do |t|
      t.bigint :tenant_id, null: false
      t.references :einvoice_submission, null: false, foreign_key: true, index: { unique: true }
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.string :provider, null: false
      t.string :status, null: false, default: "prepared"
      t.string :request_id, null: false
      t.string :reason_code, null: false, limit: 1
      t.string :remarks, null: false, limit: 100
      t.datetime :requested_at, null: false
      t.integer :attempt_count, null: false, default: 0
      t.datetime :last_attempt_at
      t.datetime :cancelled_at
      t.jsonb :provider_response
      t.string :provider_response_sha256, limit: 64
      t.string :error_code
      t.text :error_message
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :einvoice_cancellations, [ :tenant_id, :request_id ], unique: true
    add_index :einvoice_cancellations, [ :tenant_id, :status ]
    add_check_constraint :einvoice_cancellations,
      "status IN ('prepared', 'submitting', 'cancelled', 'rejected', 'indeterminate')",
      name: "einvoice_cancellations_status_valid"
    add_check_constraint :einvoice_cancellations, "reason_code IN ('1', '2')",
      name: "einvoice_cancellations_reason_valid"
    add_check_constraint :einvoice_cancellations, "attempt_count >= 0",
      name: "einvoice_cancellations_attempt_count_nonnegative"
    add_check_constraint :einvoice_cancellations,
      <<~SQL.squish,
        (status <> 'cancelled') OR
        (cancelled_at IS NOT NULL AND provider_response IS NOT NULL AND
         provider_response_sha256 IS NOT NULL)
      SQL
      name: "einvoice_cancellations_evidence_complete"
  end
end
