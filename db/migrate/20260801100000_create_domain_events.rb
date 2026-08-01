# frozen_string_literal: true

# The non-financial event store — the second of the two signed logs.
#
# `ledger_events` is the financial system of record (every double-entry posting).
# `domain_events` is its structural twin for *module lifecycle* facts that are NOT
# postings: a contract signed, a purchase order approved, a vendor onboarded. Modules
# (contract management, procurement, vendor management) append here; when a lifecycle
# fact also has an accounting consequence, the module ALSO posts to `ledger_events`.
# Two streams, one integrity model.
#
# Deliberately structural-identical to ledger_events so both logs share ONE hash-chain
# byte contract (conformance/spec/canonical-json.md, audit-hash-v2). The hashed preimage
# columns (prev_hash, ts, actor, action, ref, origin, payload) carry the same meaning and
# are hashed by the same Folio::KhataHash bridge. Folio-only scoping columns (tenant_id,
# office_id, seq, actor_user_id, signature) sit alongside and are NOT part of the preimage.
#
# What is DIFFERENT from ledger_events, on purpose:
#   * a separate table → a separate per-tenant seq chain, so a burst of contract events
#     never renumbers or serialises against financial postings;
#   * a separate advisory-lock namespace (see DomainEvent.acquire_tenant_lock!);
#   * `action` is governed by DomainEvents::Kinds — a domain event may only carry a
#     registered lifecycle kind, where ledger_events accepts any posting verb.
#
# It is NOT part of Bahi's .khata financial corpus (Bahi has no contracts). It reuses the
# same hashing MACHINERY; it does not widen the shared financial conformance contract.
class CreateDomainEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :domain_events do |t|
      # --- Folio scoping (not hashed) ---
      t.bigint   :tenant_id,     null: false
      t.bigint   :office_id
      t.bigint   :seq,           null: false   # per-tenant monotonic, gapless
      t.bigint   :actor_user_id                # real identity behind `actor`
      t.binary   :signature                    # ECDSA-P256 over the hash (deferred like ledger_events)
      t.datetime :recorded_at,   null: false, default: -> { "clock_timestamp()" }

      # --- The hashed preimage, exactly as .khata audit-hash-v2 defines it ---
      t.string  :prev_hash,     null: false, limit: 64
      t.string  :hash_hex,      null: false, limit: 64
      t.integer :hash_version,  null: false, default: 2
      t.string  :ts,            null: false   # string, not timestamp — hashed verbatim
      t.string  :actor,         null: false
      t.string  :action,        null: false   # a registered DomainEvents::Kinds kind
      t.string  :ref
      t.string  :origin,        null: false
      t.text    :payload,       null: false   # ALREADY-canonicalised JSON string
    end

    add_index :domain_events, [ :tenant_id, :seq ], unique: true
    add_index :domain_events, [ :tenant_id, :hash_hex ], unique: true
    add_index :domain_events, [ :tenant_id, :office_id, :seq ]
    add_index :domain_events, [ :tenant_id, :action ]

    # seq is 1-based and monotonic; verify_chain walks `seq > 0` from last_seq=0, so a
    # row forged at seq <= 0 would sit unvisited. ledger_events learned this in a
    # follow-up migration (add_seq_positive_check_to_ledger_events); domain_events is
    # born with the constraint. Making it unrepresentable beats detecting it.
    execute <<~SQL
      ALTER TABLE domain_events
        ADD CONSTRAINT domain_events_seq_positive CHECK (seq > 0);
    SQL

    # Append-only enforced by the DATABASE, not by app convention — the same guarantee
    # that makes ledger_events trustworthy. A callback is a suggestion; a trigger is a law.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION folio_domain_events_append_only()
      RETURNS TRIGGER AS $$
      BEGIN
        RAISE EXCEPTION
          'domain_events is append-only: % on row id=% rejected',
          TG_OP, COALESCE(OLD.id, NEW.id)
          USING ERRCODE = 'restrict_violation';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER domain_events_no_update
        BEFORE UPDATE ON domain_events
        FOR EACH ROW EXECUTE FUNCTION folio_domain_events_append_only();

      CREATE TRIGGER domain_events_no_delete
        BEFORE DELETE ON domain_events
        FOR EACH ROW EXECUTE FUNCTION folio_domain_events_append_only();

      CREATE TRIGGER domain_events_no_truncate
        BEFORE TRUNCATE ON domain_events
        FOR EACH STATEMENT EXECUTE FUNCTION folio_domain_events_append_only();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS domain_events_no_truncate ON domain_events;
      DROP TRIGGER IF EXISTS domain_events_no_delete   ON domain_events;
      DROP TRIGGER IF EXISTS domain_events_no_update   ON domain_events;
      DROP FUNCTION IF EXISTS folio_domain_events_append_only();
    SQL
    drop_table :domain_events
  end
end
