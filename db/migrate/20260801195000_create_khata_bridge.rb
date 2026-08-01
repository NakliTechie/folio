# frozen_string_literal: true

class CreateKhataBridge < ActiveRecord::Migration[8.1]
  def up
    add_column :tenants, :khata_workspace_id, :uuid, null: false, default: -> { "gen_random_uuid()" }
    add_index :tenants, :khata_workspace_id, unique: true

    create_table :external_signing_keys do |t|
      t.references :tenant, null: false, foreign_key: true
      t.uuid :source_workspace_id, null: false
      t.string :algorithm, null: false, default: "ecdsa-p256-sha256"
      t.jsonb :public_key_jwk, null: false
      t.string :fingerprint, null: false, limit: 64
      t.timestamps
    end
    add_index :external_signing_keys, %i[tenant_id source_workspace_id fingerprint],
      unique: true, name: "index_external_signing_keys_on_source_identity"
    add_check_constraint :external_signing_keys,
      "algorithm = 'ecdsa-p256-sha256'", name: "external_signing_keys_algorithm_valid"

    add_column :ledger_events, :external_signing_key_id, :bigint
    add_index :ledger_events, :external_signing_key_id
    change_column_null :ledger_events, :prev_hash, true
    add_column :entry_lines, :account_name, :string

    create_table :khata_import_runs do |t|
      t.references :tenant, null: false, foreign_key: true, index: { unique: true }
      t.references :imported_by, null: false, foreign_key: { to_table: :users }
      t.references :external_signing_key, foreign_key: true
      t.bigint :domain_event_id, null: false
      t.uuid :source_workspace_id, null: false
      t.string :source_filename, null: false
      t.string :archive_sha256, null: false, limit: 64
      t.string :books_sha256, null: false, limit: 64
      t.string :source_audit_head, null: false, limit: 64
      t.integer :source_audit_rows, null: false
      t.jsonb :source_manifest, null: false
      t.jsonb :import_counts, null: false
      t.jsonb :conformance, null: false
      t.timestamps
    end
    add_index :khata_import_runs, %i[tenant_id archive_sha256], unique: true

    execute <<~SQL
      CREATE FUNCTION folio_khata_evidence_immutable() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '% is immutable: % on row id=% rejected', TG_TABLE_NAME, TG_OP, OLD.id;
      END;
      $$;
      CREATE TRIGGER external_signing_keys_immutable
        BEFORE UPDATE OR DELETE ON external_signing_keys
        FOR EACH ROW EXECUTE FUNCTION folio_khata_evidence_immutable();
      CREATE TRIGGER khata_import_runs_immutable
        BEFORE UPDATE OR DELETE ON khata_import_runs
        FOR EACH ROW EXECUTE FUNCTION folio_khata_evidence_immutable();

      CREATE FUNCTION folio_tenant_khata_workspace_immutable() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.khata_workspace_id IS DISTINCT FROM OLD.khata_workspace_id THEN
          RAISE EXCEPTION 'tenant khata_workspace_id is immutable';
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER tenants_khata_workspace_immutable
        BEFORE UPDATE ON tenants
        FOR EACH ROW EXECUTE FUNCTION folio_tenant_khata_workspace_immutable();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS tenants_khata_workspace_immutable ON tenants;
      DROP FUNCTION IF EXISTS folio_tenant_khata_workspace_immutable();
      DROP TRIGGER IF EXISTS khata_import_runs_immutable ON khata_import_runs;
      DROP TRIGGER IF EXISTS external_signing_keys_immutable ON external_signing_keys;
      DROP FUNCTION IF EXISTS folio_khata_evidence_immutable();
    SQL
    drop_table :khata_import_runs
    remove_column :entry_lines, :account_name if column_exists?(:entry_lines, :account_name)
    change_column_null :ledger_events, :prev_hash, false
    remove_index :ledger_events, :external_signing_key_id
    remove_column :ledger_events, :external_signing_key_id
    drop_table :external_signing_keys
    remove_index :tenants, :khata_workspace_id
    remove_column :tenants, :khata_workspace_id
  end
end
