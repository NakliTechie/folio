// The canonical-JSON + audit-hash-v2 byte contract, extracted VERBATIM from Bahi's index.html
// (functions canonicalJson / auditPreimageV2, constants GENESIS_PREV / AUDIT_HASH_VERSION) and
// cross-checked against sample-data/generator.py. See ../../spec/canonical-json.md.
//
// This is the parity anchor: any engine that reproduces these bytes can share a .khata event log.
// Do not "improve" it — its output must stay byte-identical to Bahi and to the future Ruby engine.

import { createHash } from 'node:crypto';

export const GENESIS_PREV = '0'.repeat(64);
export const AUDIT_HASH_VERSION = 2;

// Recursively sort object keys; primitives/arrays via standard JSON. Byte-identical to Bahi.
export function canonicalJson(obj) {
  if (obj === null || typeof obj !== 'object') return JSON.stringify(obj);
  if (Array.isArray(obj)) return '[' + obj.map(canonicalJson).join(',') + ']';
  const keys = Object.keys(obj).sort();
  return '{' + keys.map((k) => JSON.stringify(k) + ':' + canonicalJson(obj[k])).join(',') + '}';
}

// The v2 preimage: a canonical-JSON object over all fields + the chain link. `payloadStr` is the
// ALREADY-canonicalised payload string (the audit_log.payload column), embedded as a string value.
export function auditPreimageV2(prevHash, ts, actor, action, ref, origin, payloadStr) {
  return canonicalJson({
    v: 2,
    prev: prevHash,
    ts,
    actor,
    action,
    ref: ref == null ? null : ref,
    origin,
    payload: payloadStr,
  });
}

export function sha256Hex(str) {
  return createHash('sha256').update(str, 'utf8').digest('hex');
}

// Recompute a row's hash using its declared hash_version (v2 = all fields; legacy = origin+payload).
export function rowHash({ prev_hash, ts, actor, action, ref, origin, payload, hash_version }) {
  if (hash_version === 2 || hash_version === '2') {
    return sha256Hex(auditPreimageV2(prev_hash, ts, actor, action, ref, origin, payload));
  }
  return sha256Hex((prev_hash || '') + (origin || '') + (payload || ''));
}
