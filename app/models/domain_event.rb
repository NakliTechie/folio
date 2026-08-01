# frozen_string_literal: true

# One link in a tenant's append-only, hash-chained NON-FINANCIAL event log — the
# structural twin of LedgerEvent. Read LedgerEvent first: this class mirrors its chain
# mechanics deliberately, so the two logs share one integrity model and one hashing
# byte contract (Folio::KhataHash / audit-hash-v2).
#
# Two things are intentionally NOT shared with LedgerEvent:
#   * the table and its per-tenant seq chain are separate (financial vs lifecycle);
#   * the advisory-lock namespace is separate, so appending a domain event never
#     serialises against a financial posting for the same tenant.
# What IS shared: the hashed preimage columns, Folio::KhataHash, and the genesis/gap/
# link/hash-mismatch verification semantics. The append!/verify_chain orchestration is
# mirrored rather than extracted so the financial model stays byte-for-byte untouched;
# a future refactor may unify both under one HashChainedLog concern once both are proven.
#
# There are no update or destroy paths here on purpose — the database rejects both
# (see CreateDomainEvents). A correction is a new compensating event, never a mutation.
class DomainEvent < ApplicationRecord
  self.table_name = "domain_events"

  # `hash` is Object#hash in Ruby; the column is hash_hex to avoid shadowing it.
  validates :tenant_id, :seq, :hash_hex, :ts, :actor, :action, :origin, :payload, presence: true
  validates :hash_hex, length: { is: 64 }
  # Unlike ledger_events, `action` is governed: a domain event may only carry a
  # registered lifecycle kind. This is the whole point of the registry — the
  # non-financial log stays legible because kinds are a closed, reviewed set.
  validates :action, inclusion: {
    in: ->(_) { DomainEvents::Kinds::ALL },
    message: "%{value} is not a registered DomainEvents::Kinds kind"
  }
  # prev_hash may legitimately be '' on a genesis row (see LedgerEvent for the full
  # reasoning). The column is NOT NULL, so nil is never legal; '' is meaningful.
  validates :prev_hash, exclusion: { in: [ nil ], message: "can be '' but not nil" }
  validates :prev_hash, length: { is: 64 }, allow_blank: true

  scope :for_tenant, ->(tenant_id) { where(tenant_id: tenant_id) }
  scope :in_order,   -> { order(:seq) }

  # Appends one event, computing its chain link from the current head.
  # Callers pass an already-canonical payload string; see Folio::KhataHash.
  # Prefer DomainEvents::Record.call as the module-facing entry point — it names the
  # kind explicitly and canonicalises the payload for you.
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

  # Serializes appends for one tenant. A SEPARATE lock namespace from ledger_events
  # (first arg hashtext('domain_events') vs hashtext('ledger_events')) so the two
  # streams are independent: a financial post and a contract event for the same tenant
  # do not block each other. Both args must be int4 — hashtext maps the bigint tenant id
  # into int4; a collision only over-serialises unrelated tenants, never weakening the
  # one-tenant exclusion guarantee.
  def self.acquire_tenant_lock!(tenant_id)
    connection.execute(
      sanitize_sql_array(
        [ "SELECT pg_advisory_xact_lock(hashtext('domain_events'), hashtext(?))",
          tenant_id.to_s ]
      )
    )
  end

  # Recompute every link for a tenant. Returns {ok:, head:, rows:, broken_at:, reason:}.
  # Identical semantics to LedgerEvent.verify_chain — see there for why a row's hash is
  # computed over its OWN stored prev_hash while linkage separately asserts stored
  # prev_hash equals the running head, and why the walk is keyset on seq (never find_each).
  VERIFY_COLUMNS = %i[seq prev_hash hash_hex hash_version ts actor action ref origin payload].freeze
  VERIFY_BATCH = 1_000

  def self.verify_chain(tenant_id)
    prev = Folio::KhataHash::GENESIS_PREV
    count = 0
    last_seq = 0

    loop do
      rows = for_tenant(tenant_id)
               .where("seq > ?", last_seq)
               .order(:seq)
               .limit(VERIFY_BATCH)
               .pluck(*VERIFY_COLUMNS)
      break if rows.empty?

      rows.each do |seq, prev_hash, hash_hex, hash_version, ts, actor, action, ref, origin, payload|
        # A gap is indistinguishable from a deletion, which an append-only log must not permit.
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
