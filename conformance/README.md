# `@naklitechie/khata-conformance`

> The executable contract that keeps every `.khata` accounting engine faithful to the same
> semantics — byte for byte.

`.khata` is an open, single-file, GST-native accounting format (spec in [`spec/`](spec/)). Its
reference implementation is [Bahi](https://github.com/NakliTechie/Bahi) (a browser-native JS engine).
[Folio](https://github.com/NakliTechie/folio) reimplements the same engine in Ruby on a server. Two
engines, one format — the risk is **drift**: the day Folio's trial balance disagrees with Bahi's by
one paisa, the shared format stops being shared.

This package is the guardrail. It is **not** forked application code — it is a versioned corpus of
inputs and expected outputs plus a harness that runs *any* engine implementation against them and
fails on the first byte of divergence. The corpus is worth more than either engine: an engine can be
rewritten, the contract is what makes the rewrite provably faithful.

## The three conformance tiers

| Tier | Name | What it pins | Runner |
|---|---|---|---|
| **F** | Format & integrity | Structural + accounting invariants any conforming `.khata` must satisfy (TB ties to zero, every entry balanced, audit hash-walk clean, snapshot columns frozen, GST intra/inter routing, TDS ties, stock ≥ 0, …). Engine-agnostic — checked directly against the file. | `harness/format_suite.py` (stdlib only) |
| **C** | Canonicalisation + audit chain | The cryptographic core that **must** be identical across engines: for every audit row, `sha256(canonicalJson({v:2,prev,ts,actor,action,ref,origin,payload}))` reproduces the stored `hash`; genesis + manifest-head checks. If an engine's `canonicalJson` or hash preimage differs by one byte, event-sourcing across engines is broken. | `harness/run.mjs` |
| **R** | Report golden outputs | Accounting semantics: a fixed report set (trial balance, account-type totals, GST outward summary, stock on-hand) serialised as canonical JSON and committed as golden fixtures. The engine recomputes them; the harness asserts byte-identity. | `harness/run.mjs` |

Tier F is portable and engine-independent. Tiers C and R run through a language-neutral
**engine adapter** (see [`adapters/README.md`](adapters/README.md)) so a new engine proves conformance
by shipping one small adapter — no changes to this package.

## The corpus

Three realistic, deterministic sample files (`corpus/files/`), each ~2 fiscal years of postings:

| File | Business | GST profile | Home state |
|---|---|---|---|
| `pharma.khata` | Vaidya Life Sciences Pvt Ltd | goods **and** services, credit notes, advances | MH |
| `manufacturing.khata` | Shree Krishna Steel Industries Ltd | goods only, heavy inventory | GJ |
| `consulting.khata` | Arjun Rao Advisory LLP | services only, no stock, no purchases | KA |

They are the frozen output of Bahi's conforming posting logic (schema v12), carrying a valid
hash-chained + ECDSA-signed audit log. Their SHA-256s are pinned in `corpus/manifest.json` — the
files are inputs *and*, via their own audit chain, self-describing golden.

## Run it

```sh
# everything (engine adapter tiers C+R, then format suite F)
npm test

# individually
npm run test:engine     # Tier C + R via the JS reference adapter
npm run test:format     # Tier F (Python, stdlib sqlite3)

# regenerate Tier R golden fixtures from the reference adapter (after an intentional change)
npm run gen-fixtures
```

Requires **Node ≥ 22.5** (uses the built-in `node:sqlite` — zero native deps, no `npm install`) and
**Python 3**.

## Layout

```
conformance/
├── VERSION                    package version (semver)
├── package.json               scripts; name @naklitechie/khata-conformance
├── spec/
│   ├── khata-format.md         the format spec, v1.0 (verbatim, versioned)
│   ├── khata-format-v12-addendum.md   schema v6→v12 (the doc lags reality; this reconciles)
│   └── canonical-json.md       the byte-for-byte canonicalJson + audit-hash contract
├── corpus/
│   ├── files/*.khata           the 3 sample files (inputs)
│   ├── fixtures/<file>/<query>.json   Tier R golden outputs
│   ├── manifest.json           machine-readable case + tier + adapter-query declaration
│   └── invariants.json         Tier F assertions (the ported 53-test suite)
├── adapters/
│   ├── README.md               the engine-adapter contract (how to make a new engine conform)
│   └── js/                      reference adapter — Bahi's engine semantics, verbatim
└── harness/
    ├── run.mjs                  Tier C + R runner (byte-for-byte)
    ├── gen-fixtures.mjs         (re)generate Tier R golden
    └── format_suite.py          Tier F runner
```

## Provenance & extraction

Vendored into the Folio repo for M0 (decision recorded in Folio `plan/history.md`). Authored
self-contained so `git subtree split --prefix=conformance` extracts it to a standalone
`NakliTechie/khata-conformance` repo once Bahi is wired in as a second consumer. The spec is CC0;
the corpus is synthetic.
