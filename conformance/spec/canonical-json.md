# The canonical-JSON + audit-hash byte contract

> This is the single most load-bearing piece of the whole format for a **multi-engine** world. If two
> engines disagree here by one byte, they cannot share an event log — the same posting produces two
> different `hash`es, the chains fork, and `.khata` interop breaks. Every conforming engine MUST
> reproduce this exactly. Extracted verbatim from Bahi `index.html` and cross-checked against
> `sample-data/generator.py` (an independent Python implementation that produces the corpus).

## 1. `canonicalJson(value)`

A deterministic serializer: recursively sort object keys, otherwise defer to standard JSON encoding.

Reference (Bahi `index.html`):

```js
function canonicalJson(obj) {
  if (obj === null || typeof obj !== 'object') return JSON.stringify(obj);
  if (Array.isArray(obj)) return '[' + obj.map(canonicalJson).join(',') + ']';
  const keys = Object.keys(obj).sort();
  return '{' + keys.map(k => JSON.stringify(k) + ':' + canonicalJson(obj[k])).join(',') + '}';
}
```

Rules a conforming implementation MUST honour:

1. **Object keys are sorted** ascending by code unit (JavaScript `Array.prototype.sort` default —
   UTF-16 code-unit order; for the ASCII keys used in payloads this is plain byte order).
2. **No insignificant whitespace.** `:` and `,` separators only, no spaces, no newlines.
3. **Primitives use standard JSON encoding** — `JSON.stringify` semantics: strings double-quoted with
   `\"`, `\\`, `\n`, `\t`, `\r`, `\b`, `\f` and `\uXXXX` for other control chars; `null`; `true` /
   `false`; numbers in shortest round-trip form. Non-integer/NaN/Infinity do not occur in payloads
   (money is integer paise).
4. **Arrays preserve order** (only objects are reordered).
5. The function is applied **recursively** to every nested object and array.

A `payload` is itself first serialized with `canonicalJson` into a **string**, and that string is
stored in `audit_log.payload` and fed into the preimage below as an opaque string (it is not
re-parsed).

## 2. Audit preimage (`hash_version = 2`)

```js
const AUDIT_HASH_VERSION = 2;
const GENESIS_PREV = '0'.repeat(64);          // 64 hex zeros

function auditPreimageV2(prevHash, ts, actor, action, ref, origin, payloadStr) {
  return canonicalJson({
    v: 2,
    prev: prevHash,
    ts, actor, action,
    ref: ref == null ? null : ref,
    origin,
    payload: payloadStr,          // the ALREADY-canonicalised payload string
  });
}
```

The preimage is a canonical-JSON object with **exactly these 8 keys** (`action`, `actor`, `origin`,
`payload`, `prev`, `ref`, `ts`, `v` after sorting). `payload` is the string from step 1, embedded as a
JSON string value (so it is double-quoted and its internal quotes are escaped — a string within a
string). `ref` is JSON `null` when absent, never the empty string.

## 3. Hash + chain

```
hash = lowercase_hex( SHA-256( UTF-8 bytes of the preimage string ) )
```

Chain rules (§5 of the format spec, formalised for v2):

- The first row's `prev_hash` is `GENESIS_PREV` (`"0"*64`). *(The spec §5.2 also tolerates `""` or
  `NULL` for legacy genesis rows; the corpus uses `"0"*64`.)*
- Each subsequent row's `prev_hash` equals the previous row's `hash`.
- `manifest.integrity.auditHead` equals the last row's `hash`.

Legacy `hash_version` (absent or not `2`) uses the v1 preimage `prevHash + (origin||'') + payload`.
The corpus is entirely `hash_version = 2`; a conforming engine that only targets v12 files need only
implement v2, but MUST still recompute using each row's declared `hash_version`.

## 4. Signature (informative for this tier)

`signature` is base64(ECDSA P-256 / SHA-256 over the **hex** `hash` string bytes), verifiable against
`manifest.integrity.signedBy` (a P-256 JWK). Tier C asserts the **hash chain** (deterministic, key-
independent); signature verification is a separate, key-dependent check that Bahi performs on open and
that Folio will perform against enrolled per-user keys (M2). It is out of scope for byte-for-byte
engine parity because signatures are non-deterministic (ECDSA nonce) — two correct engines produce
different valid signatures over the same hash. **The hash is the parity anchor; the signature is the
authenticity check.**

## 5. Worked reference

The corpus is the golden. `harness/run.mjs` (Tier C) recomputes §2–§3 for **every** `audit_log` row
in all three files (≈ 9 186 rows in `pharma.khata` alone) and asserts the recomputed hash equals the
stored `hash` and the chain links. Because Bahi (JS) and `generator.py` (Python) already agree on
these bytes, a third engine (Folio's Ruby) reproducing them is the proof that the event log is truly
portable.

### Minimal Ruby sketch (what M1 must satisfy)

```ruby
def canonical_json(v)
  case v
  when Hash  then '{' + v.keys.sort.map { |k| k.to_json + ':' + canonical_json(v[k]) }.join(',') + '}'
  when Array then '[' + v.map { |e| canonical_json(e) }.join(',') + ']'
  else v.to_json
  end
end

def audit_hash_v2(prev, ts, actor, action, ref, origin, payload_str)
  pre = canonical_json({ 'v' => 2, 'prev' => prev, 'ts' => ts, 'actor' => actor,
                         'action' => action, 'ref' => ref, 'origin' => origin,
                         'payload' => payload_str })
  Digest::SHA256.hexdigest(pre)
end
```

The one subtlety a porter WILL trip on: `payload` is the **canonicalised string**, hashed as a string
value inside the preimage — do not pass the payload object. Bahi stores that exact string in
`audit_log.payload`, so on verify you feed the stored `payload` column straight through.
