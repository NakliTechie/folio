# Engine-adapter contract

An **adapter** is the thin bridge between an accounting engine and this conformance harness. It is the
*only* thing an engine must ship to prove conformance — the corpus, the manifest, and the harness are
shared and unchanged. Bahi's JS engine conforms through [`js/adapter.mjs`](js/adapter.mjs); Folio's
Ruby engine will conform through a `ruby/` adapter at M1; a third-party `.khata` reader conforms the
same way.

## Invocation

```
<adapter...> <query> <path-to.khata>
```

- The harness spawns the adapter with the **package root** (`conformance/`) as the working directory,
  passing the query name and a path to a corpus `.khata` (relative to the package root, e.g.
  `corpus/files/pharma.khata`).
- The adapter reads the file, computes the answer, writes **canonical JSON** to **stdout**, and exits
  **0**. Any diagnostics go to stderr. A non-zero exit is a conformance failure.
- The adapter command is configured via `--adapter '<cmd>'` (default `node adapters/js/adapter.mjs`);
  e.g. `node harness/run.mjs --adapter 'ruby adapters/ruby/adapter.rb'`.

## Canonical JSON

Output MUST be **canonical JSON**: object keys sorted ascending, no insignificant whitespace, standard
JSON string/number encoding. This is the same serialization defined in
[`../spec/canonical-json.md`](../spec/canonical-json.md) and implemented in
[`js/canonical-json.mjs`](js/canonical-json.mjs) — Tier R compares stdout to the golden fixture
**byte for byte**, so key order and spacing matter. Money is always **integer paise** (never a float).

## Queries

| Query | Output shape |
|---|---|
| `verify-chain` | `{ "ok": bool, "count": int, "badRows": [ {id, reason, …} ] }` — recompute `sha256(canonicalJson({v:2,…}))` for every `audit_log` row (per its `hash_version`) and walk the chain. `ok` is true iff every row's hash reproduces and every `prev_hash` links. This is **Tier C** — the byte-for-byte crypto contract. |
| `trial-balance` | `[ {account_id:int, name:str, type:str, debit:int, credit:int} ]` — one entry per account with postings, aggregated over `entry_lines`, **sorted by `account_id`**. `type` ∈ asset/liability/equity/income/expense. Paise. |
| `account-type-totals` | `[ {type:str, debit:int, credit:int} ]` — debit/credit sums grouped by account type, **sorted by `type`**. Paise. |
| `gst-outward-summary` | `{ invoice_count:int, taxable:int, cgst:int, sgst:int, igst:int, cess:int }` — totals over posted invoices (`status='posted'`). Paise. |
| `stock-on-hand` | `[ {item_id:int, item_name:str, on_hand_qty:int} ]` — closing quantity per item = Σ(in) − Σ(out) over `stock_movements`, **sorted by `item_id`**. Empty array when there is no inventory. |

Tiers C and R run through these queries. Tier F (format & integrity invariants) is engine-agnostic and
does **not** use the adapter — it checks the file directly (`harness/format_suite.py`).

## Writing a new adapter (e.g. Folio's Ruby engine)

1. Parse `argv`: `[query, khataPath]`.
2. Open the `.khata` (a zip) and read `books.sqlite`.
3. Implement the five queries with the exact shapes above. For `verify-chain`, reuse the byte contract
   in [`../spec/canonical-json.md`](../spec/canonical-json.md) — the one subtlety is that `payload` is
   the already-canonicalised **string** from the `audit_log.payload` column, embedded as a string
   value inside the v2 preimage. The Ruby sketch in that spec is a drop-in starting point.
4. Serialize each result with **your engine's own `canonicalJson`** and print it. If your
   `canonicalJson` is faithful, Tier R passes byte-for-byte; if it isn't, Tier R is exactly the test
   that catches it.
5. Run `node harness/run.mjs --adapter 'ruby adapters/ruby/adapter.rb'`.

The reference adapter is intentionally small (≈150 lines of query SQL + the verbatim byte contract) so
a new adapter is a faithful port, not a reinterpretation.

## The point

Two engines can only share a `.khata` if they agree here. Tier C proves the event log is portable
(same hashes); Tier R proves the accounting is identical (same reports). When Folio's Ruby adapter goes
green against this corpus, "Folio reproduces Bahi byte-for-byte" stops being an aspiration and becomes
a CI gate.
