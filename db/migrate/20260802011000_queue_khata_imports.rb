# frozen_string_literal: true

class QueueKhataImports < ActiveRecord::Migration[8.1]
  def change
    create_table :khata_import_uploads do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.references :khata_import_run, foreign_key: true
      t.string :source_filename, null: false
      t.string :archive_sha256, null: false, limit: 64
      t.binary :archive_bytes
      t.string :status, null: false, default: "queued"
      t.text :error_message
      t.timestamps
    end
    add_index :khata_import_uploads, :tenant_id, unique: true,
      where: "status IN ('queued', 'processing')",
      name: "index_khata_import_uploads_on_active_tenant"
    add_check_constraint :khata_import_uploads,
      "status IN ('queued', 'processing', 'succeeded', 'failed')",
      name: "khata_import_uploads_status_valid"
    add_check_constraint :khata_import_uploads,
      "archive_bytes IS NULL OR octet_length(archive_bytes) <= 104857600",
      name: "khata_import_uploads_size_valid"
  end
end
