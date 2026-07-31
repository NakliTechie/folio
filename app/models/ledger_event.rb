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
  # must be preserved verbatim rather than normalised. But the column is NOT NULL, so
  # nil is never legal: allow_blank alone let nil through validation and into a
  # PG::NotNullViolation. '' is meaningful here; nil is not.
  validates :prev_hash, exclusion: { in: [ nil ], message: "can be '' but not nil" }
  validates :prev_hash, length: { is: 64 }, allow_blank: true

  scope :for_tenant, ->(tenant_id) { where(tenant_id: tenant_id) }
  scope :in_order,   -> { order(:seq) }

  # Appends one event, computing its chain link from the current head.
  # Callers pass an already-canonical payload string; see Folio::KhataHash.
  def self.append!(tenant_id:, actor:, action:, origin:, ts:, payload_str:, ref: nil,
                   office_id: nil, actor_user_id: nil, signature: nil)
    transaction do
      acquire_tenant_lock!(tenant_id)

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

  # Serializes both event append and projection maintenance for one tenant. Rebuild must
  # hold the same transaction-scoped lock as writers; otherwise a post can land between
  # the projection wipe and event scan and be projected twice.
  #
  # Both arguments must be int4 — the (int, int) overload is the only two-arg form.
  # hashtext maps bigint tenant ids into int4. A collision only serializes unrelated
  # tenants unnecessarily; it cannot weaken the one-tenant exclusion guarantee.
  def self.acquire_tenant_lock!(tenant_id)
    connection.execute(
      sanitize_sql_array(
        [ "SELECT pg_advisory_xact_lock(hashtext('ledger_events'), hashtext(?))",
          tenant_id.to_s ]
      )
    )
  end

  # Recompute every link for a tenant. Returns {ok:, head:, rows:, broken_at:, reason:}.
  # This is the routine integrity check and the first half of rebuild-from-events.
  #
  # Two DISTINCT assertions, and conflating them is a trap worth naming: a row's hash
  # is computed over the row's OWN stored prev_hash (that is what went into the
  # preimage when it was written), while chain linkage separately asserts that stored
  # prev_hash equals the running head. Recomputing with the walked head instead makes
  # every row after the first fork fail spuriously. Matches the reference adapter.
  # Only the columns that go into the hash, plus seq. `payload` is unbounded text and
  # loading whole records for a multi-year tenant is needless pressure.
  VERIFY_COLUMNS = %i[seq prev_hash hash_hex hash_version ts actor action ref origin payload].freeze
  VERIFY_BATCH = 1_000

  def self.verify_chain(tenant_id)
    prev = Folio::KhataHash::GENESIS_PREV
    count = 0
    last_seq = 0

    # Keyset pagination on seq. NOT find_each: find_each discards any scope order and
    # forces batching by primary key, so `order(:seq)` was silently ignored and the
    # chain was walked in id order. That coincides with seq order only while rows are
    # inserted in sequence — which stops being true the moment anything is imported,
    # backfilled or interleaved, and then a sound chain fails or a broken one passes.
    loop do
      rows = for_tenant(tenant_id)
               .where("seq > ?", last_seq)
               .order(:seq)
               .limit(VERIFY_BATCH)
               .pluck(*VERIFY_COLUMNS)
      break if rows.empty?

      rows.each do |seq, prev_hash, hash_hex, hash_version, ts, actor, action, ref, origin, payload|
        # A gap is indistinguishable from a deletion, which an append-only log must
        # not permit. The unique index stops duplicate seq; nothing stopped holes.
        unless seq == last_seq + 1
          return { ok: false, head: prev, rows: count, broken_at: seq, reason: :seq_gap }
        end

        # Genesis tolerance: a first row may record '', NULL, or 64 zeros.
        genesis_ok = prev == Folio::KhataHash::GENESIS_PREV &&
                     (prev_hash.blank? || prev_hash == Folio::KhataHash::GENESIS_PREV)

        unless prev_hash == prev || genesis_ok
          return { ok: false, head: prev, rows: count, broken_at: seq, reason: :chain_link }
        end

        expected = Folio::KhataHash.row_hash(
          "hash_version" => hash_version, "prev_hash" => prev_hash, "ts" => ts,
          "actor" => actor, "action" => action, "ref" => ref,
          "origin" => origin, "payload" => payload
        )
        unless hash_hex == expected
          return { ok: false, head: prev, rows: count, broken_at: seq, reason: :hash_mismatch }
        end

        prev = hash_hex
        last_seq = seq
        count += 1
      end
    end

    { ok: true, head: prev, rows: count, broken_at: nil, reason: nil }
  end
end
