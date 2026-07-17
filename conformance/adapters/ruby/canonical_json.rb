# frozen_string_literal: true

# The canonical-JSON + audit-hash-v2 byte contract, ported to Ruby to be byte-identical to Bahi's JS
# (adapters/js/canonical-json.mjs) and to generator.py. See ../../spec/canonical-json.md.
#
# This is the parity anchor: Folio's Ruby engine can only share a .khata event log with Bahi if these
# bytes match exactly. Portable across Ruby 2.6 → 3.x. Do not "improve" it.

require 'json'
require 'digest'

module KhataCanonical
  GENESIS_PREV = '0' * 64
  AUDIT_HASH_VERSION = 2

  module_function

  # Recursively sort object keys; primitives/arrays via standard JSON. Byte-identical to the JS
  # canonicalJson: objects → sorted keys, no whitespace; arrays keep order; scalars via JSON encoding.
  def canonical_json(value)
    case value
    when Hash
      inner = value.keys.map(&:to_s).sort.map do |k|
        # value[k] may have been keyed by string; fall back to symbol if needed.
        v = value.key?(k) ? value[k] : value[k.to_sym]
        k.to_json + ':' + canonical_json(v)
      end
      '{' + inner.join(',') + '}'
    when Array
      '[' + value.map { |e| canonical_json(e) }.join(',') + ']'
    else
      # String / Integer / true / false / nil → standard JSON scalar encoding.
      value.to_json
    end
  end

  # The v2 preimage: a canonical-JSON object over all fields + the chain link. `payload_str` is the
  # ALREADY-canonicalised payload string (the audit_log.payload column), embedded as a string value.
  def audit_preimage_v2(prev_hash, ts, actor, action, ref, origin, payload_str)
    canonical_json(
      'v' => 2,
      'prev' => prev_hash,
      'ts' => ts,
      'actor' => actor,
      'action' => action,
      'ref' => ref.nil? ? nil : ref,
      'origin' => origin,
      'payload' => payload_str
    )
  end

  def sha256_hex(str)
    Digest::SHA256.hexdigest(str)
  end

  # Recompute a row's hash using its declared hash_version (v2 = all fields; legacy = origin+payload).
  def row_hash(row)
    hv = row['hash_version']
    if hv == 2 || hv == '2'
      sha256_hex(audit_preimage_v2(row['prev_hash'], row['ts'], row['actor'], row['action'],
                                   row['ref'], row['origin'], row['payload']))
    else
      sha256_hex("#{row['prev_hash']}#{row['origin']}#{row['payload']}")
    end
  end
end
