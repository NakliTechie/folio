# frozen_string_literal: true

# One link in a tenant's append-only, hash-chained event log.
#
# There are no update or destroy paths here on purpose. The database rejects both
# (see CreateLedgerEvents), so anything that looks like a correction must be a new
# compensating event — the same rule Bahi's audit_log follows, and the reason a
# .khata log can be replayed into Folio and back out again.
class LedgerEvent < ApplicationRecord
  self.table_name = "ledger_events"

  # `hash` is Object#hash in Ruby; the column is hash_hex to avoid shadowing it.
  validates :tenant_id, :seq, :hash_hex, :ts, :actor, :action, :origin, :payload, presence: true
  validates :hash_hex, length: { is: 64 }
  # prev_hash may legitimately be '' on a genesis row — .khata logs in the wild record
  # genesis as '', NULL, or 64 zeros, and the stored value is what was hashed, so it
  # must be preserved verbatim rather than normalised.
  validates :prev_hash, length: { is: 64 }, allow_blank: true

  scope :for_tenant, ->(tenant_id) { where(tenant_id: tenant_id) }
  scope :in_order,   -> { order(:seq) }

  # Appends one event, computing its chain link from the current head.
  # Callers pass an already-canonical payload string; see Folio::KhataHash.
  def self.append!(tenant_id:, actor:, action:, origin:, ts:, payload_str:, ref: nil,
                   office_id: nil, actor_user_id: nil, signature: nil)
    transaction do
      # Serialize appends per tenant so two writers cannot fork the chain. The unique
      # index on (tenant_id, seq) is the backstop; this lock is what stops the retry.
      connection.execute(
        "SELECT pg_advisory_xact_lock(hashtext('ledger_events'), #{tenant_id.to_i})"
      )

      head = for_tenant(tenant_id).in_order.last
      prev = head&.hash_hex || Folio::KhataHash::GENESIS_PREV
      next_seq = (head&.seq || 0) + 1

      hash_hex = Folio::KhataHash.event_hash(
        prev_hash: prev, ts: ts, actor: actor, action: action,
        ref: ref, origin: origin, payload_str: payload_str
      )

      create!(
        tenant_id: tenant_id, office_id: office_id, seq: next_seq,
        actor_user_id: actor_user_id, signature: signature,
        prev_hash: prev, hash_hex: hash_hex, hash_version: Folio::KhataHash::HASH_VERSION,
        ts: ts, actor: actor, action: action, ref: ref, origin: origin, payload: payload_str
      )
    end
  end

  # Recompute every link for a tenant. Returns {ok:, head:, rows:, broken_at:, reason:}.
  # This is the routine integrity check and the first half of rebuild-from-events.
  #
  # Two DISTINCT assertions, and conflating them is a trap worth naming: a row's hash
  # is computed over the row's OWN stored prev_hash (that is what went into the
  # preimage when it was written), while chain linkage separately asserts that stored
  # prev_hash equals the running head. Recomputing with the walked head instead makes
  # every row after the first fork fail spuriously. Matches the reference adapter.
  def self.verify_chain(tenant_id)
    prev = Folio::KhataHash::GENESIS_PREV
    count = 0

    for_tenant(tenant_id).in_order.find_each do |e|
      # Genesis tolerance: a first row may record '', NULL, or 64 zeros.
      genesis_ok = prev == Folio::KhataHash::GENESIS_PREV &&
                   (e.prev_hash.blank? || e.prev_hash == Folio::KhataHash::GENESIS_PREV)

      unless e.prev_hash == prev || genesis_ok
        return { ok: false, head: prev, rows: count, broken_at: e.seq, reason: :chain_link }
      end

      expected = Folio::KhataHash.row_hash(
        "hash_version" => e.hash_version, "prev_hash" => e.prev_hash, "ts" => e.ts,
        "actor" => e.actor, "action" => e.action, "ref" => e.ref,
        "origin" => e.origin, "payload" => e.payload
      )
      unless e.hash_hex == expected
        return { ok: false, head: prev, rows: count, broken_at: e.seq, reason: :hash_mismatch }
      end

      prev = e.hash_hex
      count += 1
    end

    { ok: true, head: prev, rows: count, broken_at: nil, reason: nil }
  end
end
