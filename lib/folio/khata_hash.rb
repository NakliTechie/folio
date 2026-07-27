# frozen_string_literal: true

# Bridge to the .khata audit-hash-v2 byte contract.
#
# This file deliberately contains NO hashing logic of its own. It loads the
# canonical implementation straight out of the vendored conformance package, which
# is the same file the Ruby conformance adapter runs. One implementation, one set of
# bytes — a second copy in app code is exactly how two engines silently diverge, and
# the whole point of the conformance package is that they cannot.
#
# When `conformance/` is eventually extracted to its own repo (per the M0 decision),
# this require becomes a gem require and nothing else changes.

require Rails.root.join("conformance/adapters/ruby/canonical_json").to_s

module Folio
  module KhataHash
    GENESIS_PREV = KhataCanonical::GENESIS_PREV
    HASH_VERSION = KhataCanonical::AUDIT_HASH_VERSION

    module_function

    # Canonicalise a Ruby Hash into the payload string that gets embedded in the
    # preimage AND stored verbatim in ledger_events.payload.
    def canonical_payload(hash)
      KhataCanonical.canonical_json(hash)
    end

    # The v2 chain hash for one event. `payload_str` must ALREADY be canonical —
    # passing a re-serialised hash here is the classic way to produce a chain that
    # verifies locally and fails against Bahi.
    def event_hash(prev_hash:, ts:, actor:, action:, ref:, origin:, payload_str:)
      KhataCanonical.sha256_hex(
        KhataCanonical.audit_preimage_v2(prev_hash, ts, actor, action, ref, origin, payload_str)
      )
    end

    # Recompute a stored row's hash from its own declared hash_version.
    # Accepts the .khata audit_log column names.
    def row_hash(row)
      KhataCanonical.row_hash(row)
    end
  end
end
