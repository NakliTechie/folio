# frozen_string_literal: true

class HardenKhataRecoveryAndSigning < ActiveRecord::Migration[8.1]
  def up
    create_table :khata_recovery_snapshots do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :khata_import_run, null: false, foreign_key: true, index: { unique: true }
      t.integer :schema_version, null: false, default: 1
      t.jsonb :projection, null: false
      t.string :projection_sha256, null: false, limit: 64
      t.timestamps
    end
    add_check_constraint :khata_recovery_snapshots, "schema_version = 1",
      name: "khata_recovery_snapshots_schema_version_valid"
    add_check_constraint :khata_recovery_snapshots,
      "projection_sha256 ~ '^[0-9a-f]{64}$'",
      name: "khata_recovery_snapshots_digest_valid"

    execute <<~SQL
      CREATE TRIGGER khata_recovery_snapshots_immutable
        BEFORE UPDATE OR DELETE ON khata_recovery_snapshots
        FOR EACH ROW EXECUTE FUNCTION folio_khata_evidence_immutable();
      CREATE TRIGGER khata_recovery_snapshots_no_truncate
        BEFORE TRUNCATE ON khata_recovery_snapshots
        FOR EACH STATEMENT EXECUTE FUNCTION folio_immutable_evidence_no_truncate();

      CREATE FUNCTION folio_user_signing_key_guard() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'user_signing_keys is immutable: DELETE on row id=% rejected', OLD.id;
        END IF;
        IF NEW.user_id IS DISTINCT FROM OLD.user_id
          OR NEW.key_version IS DISTINCT FROM OLD.key_version
          OR NEW.algorithm IS DISTINCT FROM OLD.algorithm
          OR NEW.public_key_pem IS DISTINCT FROM OLD.public_key_pem
          OR NEW.encrypted_private_key IS DISTINCT FROM OLD.encrypted_private_key
          OR NEW.fingerprint IS DISTINCT FROM OLD.fingerprint
          OR (OLD.active = FALSE AND NEW.active = TRUE)
          OR (OLD.retired_at IS NOT NULL AND NEW.retired_at IS DISTINCT FROM OLD.retired_at) THEN
          RAISE EXCEPTION 'user_signing_keys key material and retirement are immutable';
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER user_signing_keys_guard
        BEFORE UPDATE OR DELETE ON user_signing_keys
        FOR EACH ROW EXECUTE FUNCTION folio_user_signing_key_guard();
      CREATE TRIGGER user_signing_keys_no_truncate
        BEFORE TRUNCATE ON user_signing_keys
        FOR EACH STATEMENT EXECUTE FUNCTION folio_immutable_evidence_no_truncate();

      CREATE FUNCTION folio_actor_event_requires_signature() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.actor_user_id IS NOT NULL
          AND (NEW.signature IS NULL OR NEW.signing_key_id IS NULL) THEN
          RAISE EXCEPTION '% actor-backed events require a signature and signing key', TG_TABLE_NAME;
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER ledger_events_require_actor_signature
        BEFORE INSERT ON ledger_events
        FOR EACH ROW EXECUTE FUNCTION folio_actor_event_requires_signature();
      CREATE TRIGGER domain_events_require_actor_signature
        BEFORE INSERT ON domain_events
        FOR EACH ROW EXECUTE FUNCTION folio_actor_event_requires_signature();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS domain_events_require_actor_signature ON domain_events;
      DROP TRIGGER IF EXISTS ledger_events_require_actor_signature ON ledger_events;
      DROP FUNCTION IF EXISTS folio_actor_event_requires_signature();
      DROP TRIGGER IF EXISTS user_signing_keys_no_truncate ON user_signing_keys;
      DROP TRIGGER IF EXISTS user_signing_keys_guard ON user_signing_keys;
      DROP FUNCTION IF EXISTS folio_user_signing_key_guard();
      DROP TRIGGER IF EXISTS khata_recovery_snapshots_no_truncate ON khata_recovery_snapshots;
      DROP TRIGGER IF EXISTS khata_recovery_snapshots_immutable ON khata_recovery_snapshots;
    SQL
    drop_table :khata_recovery_snapshots
  end
end
