# frozen_string_literal: true

# The authoritative event store. Postgres analogue of Bahi's `audit_log`.
#
# Field names deliberately mirror the .khata audit-hash-v2 preimage
# (conformance/spec/canonical-json.md): prev_hash, ts, actor, action, ref, origin,
# payload. Renaming any of them would break byte-identity with Bahi's chain, which
# is the one thing the conformance contract exists to prevent. Folio-only columns
# (tenant_id, office_id, seq, actor_user_id, signature) sit alongside and are NOT
# part of the hash preimage.
class CreateLedgerEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :ledger_events do |t|
      # --- Folio scoping (not hashed) ---
      t.bigint  :tenant_id,     null: false
      t.bigint  :office_id
      t.bigint  :seq,           null: false   # per-tenant monotonic, gapless
      t.bigint  :actor_user_id                # real identity behind `actor`
      t.binary  :signature                    # ECDSA-P256 over the hash
      t.datetime :recorded_at,  null: false, default: -> { "clock_timestamp()" }

      # --- The hashed preimage, exactly as .khata defines it ---
      t.string  :prev_hash,     null: false, limit: 64
      t.string  :hash_hex,      null: false, limit: 64
      t.integer :hash_version,  null: false, default: 2
      t.string  :ts,            null: false   # string, not timestamp — hashed verbatim
      t.string  :actor,         null: false
      t.string  :action,        null: false
      t.string  :ref
      t.string  :origin,        null: false
      t.text    :payload,       null: false   # ALREADY-canonicalised JSON string
    end

    add_index :ledger_events, [ :tenant_id, :seq ], unique: true
    add_index :ledger_events, [ :tenant_id, :hash_hex ], unique: true
    add_index :ledger_events, [ :tenant_id, :office_id, :seq ]
    add_index :ledger_events, [ :tenant_id, :action ]

    # Append-only enforced by the DATABASE, not by app convention. An ORM callback
    # is a suggestion; a trigger is a guarantee. This is never-degrade property #3.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION folio_ledger_events_append_only()
      RETURNS TRIGGER AS $$
      BEGIN
        RAISE EXCEPTION
          'ledger_events is append-only: % on row id=% rejected',
          TG_OP, COALESCE(OLD.id, NEW.id)
          USING ERRCODE = 'restrict_violation';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER ledger_events_no_update
        BEFORE UPDATE ON ledger_events
        FOR EACH ROW EXECUTE FUNCTION folio_ledger_events_append_only();

      CREATE TRIGGER ledger_events_no_delete
        BEFORE DELETE ON ledger_events
        FOR EACH ROW EXECUTE FUNCTION folio_ledger_events_append_only();

      CREATE TRIGGER ledger_events_no_truncate
        BEFORE TRUNCATE ON ledger_events
        FOR EACH STATEMENT EXECUTE FUNCTION folio_ledger_events_append_only();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS ledger_events_no_truncate ON ledger_events;
      DROP TRIGGER IF EXISTS ledger_events_no_delete   ON ledger_events;
      DROP TRIGGER IF EXISTS ledger_events_no_update   ON ledger_events;
      DROP FUNCTION IF EXISTS folio_ledger_events_append_only();
    SQL
    drop_table :ledger_events
  end
end
