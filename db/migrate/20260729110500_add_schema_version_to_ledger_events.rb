# frozen_string_literal: true

# B3.1 — payload schema_version on ledger_events (spec §9, decision D11).
#
# DISTINCT from hash_version. hash_version identifies the canonicalisation/hashing rule;
# schema_version identifies the PAYLOAD shape, so a read-time upcaster registry (pure
# functions, never rewriting stored events) can lift an old payload to the current shape
# on replay. Note the interaction with D15: fat payloads have many optional keys, every
# one OMITTED-when-absent, never null.
#
# This column is invisible to the hash. The preimage (Folio::KhataHash / VERIFY_COLUMNS)
# is exactly {hash_version, prev_hash, ts, actor, action, ref, origin, payload} — adding a
# column outside that set cannot change any stored event's hash, so the corpus stays
# byte-identical. Default 1 = the current (only) payload shape.
class AddSchemaVersionToLedgerEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :ledger_events, :schema_version, :integer, null: false, default: 1
  end
end
