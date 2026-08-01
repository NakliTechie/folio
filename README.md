# Folio — governed accounting for service businesses

> *A Bahi is one merchant's ledger book. A Folio is the governed server ledger for a team.*

**Folio** is a multi-user Rails/Postgres accounting application for India services-first businesses.
The current product operates one primary office per company with tenant-wide role assignments. It
supports governed masters, sales and purchase documents, receipts/payments, open-item settlement,
credit-event TDS, filing JSON for GSTR-1/GSTR-3B/CMP-08, offline INV-01 e-invoice preparation,
period controls, contract revenue accounting, procurement, bank reconciliation, inventory, fixed
assets, controlling, same-currency consolidation, governed migration exports, and signed append-only
financial and lifecycle event logs.

Folio shares accounting semantics and a conformance corpus with
[Bahi](https://bahi.naklitechie.com/), which remains single-office, local-first, and single-file by
design. Multi-office operation, a customer-selected second jurisdiction, live statutory-provider
activation, and external chain anchoring remain roadmap work—not current product claims.

*(Name provisional — chosen Latin/English for global reach; a "folio" is the numbered ledger page an
account is posted to, pairing with Bahi the bound book. Alt candidates: Abacus, Comptoir / Counting
House, Ledgerline. Rename = `gh repo rename` + folder move.)*

---

## 1. Why Folio exists (and why it's a separate product)
- Bahi's differentiator is **pure local-first sovereignty** — no server, nothing leaves the device.
  Multi-user/RBAC/real-time fundamentally need shared authoritative state; bolting that onto a
  file-on-disk app (E2EE relay, CRDT merge, MLS keying) was high-complexity and fought the model.
- **An authoritative server DB makes multi-user _trivial_** — real auth, row locks, transactions.
  All the exotic sync machinery evaporates. So: split the products, don't compromise either.
- **Local→server upgrade without lock-in:** owners can import a Bahi `.khata` once into a genuinely
  empty company after format, chain, declared-signature, and native-report verification. Folio can
  export a deterministic standard `.khata` copy when the books fit the v1 contract.

## 2. The load-bearing principle: a shared CONFORMANCE CONTRACT, not forked code
Folio does **not** fork Bahi's HTML. The shared asset is the **engine semantics + `.khata` format**,
made concrete as a contract Folio's Rails engine is tested against:
- **`.khata` / khata-standard format spec** — already an open standard.
- **Bahi's deterministic test corpus** (53 tests, 3 realistic sample files: pharma / manufacturing /
  consulting) → promoted to a **standalone cross-implementation conformance package**. Folio's Ruby
  posting/GST/reports engine must reproduce it **byte-for-byte**. This corpus is the anti-drift
  guardrail on the most correctness-critical logic in the system.
- The corpus is vendored read-only and enforced in CI. Extracting it into a separately versioned
  package remains planned.

## 3. Tech & topology (decided)
- **Rails 8 + Postgres** — the proven multi-tenant playbook (Trellis / Herald / Muster / Docket).
- **Multi-tenant from day one** — because hosting is **both self-hostable AND managed SaaS in
  parallel**. Self-host = the same app run single-tenant ("your server"); managed = many tenants,
  tenant-scoping always on. One codebase, two deploy topologies.
- **`schema_format = :sql`** (Herald lesson — Postgres features need the SQL schema dumper).
- Engine in **plain Ruby POROs / service objects** (portable, unit-testable against the corpus),
  Rails for the shell (auth, tenancy, RBAC, jobs, API).

## 4. Data model — event-sourced, mirroring Bahi
Bahi is already event-sourced: its append-only audit log is the source of truth and its SQLite
ledger is a projection. Folio keeps that shape, server-side:
- **`ledger_events`** (append-only, per-tenant) — the authoritative Postgres event store. Events are
  hash-chained, carry actor/origin labels, and are signed by the acting user's encrypted P-256 key.
  This proves the enrolled key signed the stored hash; trusted timestamps/external anchoring remain
  necessary before making a broad non-repudiation claim against an operator.
- **Projection tables** — governed accounts/documents plus `entries`, `entry_lines`, and signed
  integer-minor-unit amounts materialized from events. Party, item, tax, and document snapshots freeze
  the historical basis needed for ordinary replay.
- **Rebuild-from-events** — the routine recovery/read-model rebuild path, serialized against writers
  and covered through document, settlement, credit, reversal, and report follow-on operations.
- **Historical references in projections are values, not live master-data dependencies.** Replay is
  deliberately master-independent, so projection-to-master foreign keys are not used where deleting
  or superseding a current master would prevent a historical rebuild. Production posting resolves
  tenant-owned organization/configuration records before appending the authoritative event.
- **Provenance status** — posting stamps the engine version and resolved authority today. The payload
  builder supports `configVersions`, but production document posts omit it until the planned
  append-only configuration registry can provide immutable versions; that part is not yet complete.
- Concurrency = **Postgres transactions + row locks** (not CRDT). Self-balancing entries (Dr=Cr)
  keep the invariant under concurrent posting.

## 5. Tenancy & identity
- **Tenant = a firm** (an account/organization). Tenant-owned application queries bind `tenant_id`
  from the authenticated membership or resource and cross-tenant behaviour is covered by integration
  tests. PostgreSQL RLS is **not implemented yet**; it remains pre-production defense-in-depth work.
- **Auth today** — email/password sessions, invitations, password recovery, and active-session
  revocation. TOTP and Google/Microsoft SSO are planned pre-launch identity work.
- **Signing today** — signup provisions an encrypted per-user P-256 key and financial/lifecycle
  events carry independently verifiable actor signatures. Imported `.khata` events retain their
  declared external JWK identity. Key rotation/recovery, trusted head timestamps, and external
  anchoring still precede any broad non-repudiation claim.

## 6. RBAC today

The v1 operating contract uses exactly one **tenant-wide role** per user/company. Membership without
a tenant-wide role is denied. Office-scoped assignment columns are reserved, but office-only users
cannot enter the product until selected-office context and complete read/write isolation ship.

| Role | Capabilities |
|---|---|
| **Owner/Admin** | all current capabilities, including users, masters, documents, reports, and close |
| **Accountant** | governed masters, journals, invoices/bills, settlements, and reports |
| **Operator** | invoices, bills, receipts/payments, preview, and reports; no COA or period close |
| **CA / Auditor** | reports, adjustment journals, and period control; no master edits |
| **Viewer** | read-only reports, ledgers, accounts, and master data |

Capability checks run server-side. Posted entries freeze the resolved role/limit authority; the event
log is hash-chained and cryptographically signed by the acting user.

## 7. Planned multi-office / multi-entity

The schema has entity and office dimensions, but the operating product provisions and uses one
`PRIMARY` office. The planned multi-office model is:
- An office carries: GSTIN (or jurisdiction tax id), its own **prefixed voucher series** (disjoint →
  concurrent numbering never collides), default bank/cash accounts, default place-of-supply,
  assigned users+roles.
- Two shapes under one model: **separate-tax-id offices** (own books + **consolidation view**) and
  **single-tax-id branches** (office_id dimension on entries/invoices).
- **Consolidation** = group-by office over the tenant's ledger → group P&L/BS; also the unit that
  feeds the SAP export. Cross-jurisdiction consolidation needs a reporting-currency policy (later).

## 8. Planned jurisdiction profiles / accounting standards
The `JurisdictionProfile` work (COA template + statement presentation + terminology + tax adapter +
currency + FY convention) is more an enterprise/multi-entity concern → **lands primarily in Folio**
(Bahi can stay India-first). Profiles: IN-IGAAP, IN-INDAS, UK-FRS102, MY-MPERS, SG-SFRS, US-GAAP,
NG-IFRS. Tax-adapter abstraction (GST↔VAT↔SST↔sales-tax) is the deep refactor and is server-side.
Cross-ref: `bahi/plan/2026-07-16-accounting-standards-multi-jurisdiction.md`.

## 9. Interop bridge (Bahi ↔ Folio)

The product bridge inspects archives without extracting paths, verifies the manifest/books hash,
SQLite invariants, exact audit chain, and declared P-256 signatures before one transactional import.
It preserves the source head and event signatures, freezes historical account names, links imported
journals to source events, and requires native trial-balance/account-type parity before commit. The
same archive is idempotent; a different file or an operational company is rejected because the
server is authoritative, not an offline merge target.

Export writes deterministic `.khata` v1/schema 12 files and proves round-trip chain/report parity.
It deliberately fails closed for multi-entity, non-INR, extension-ledger, layered/statistical, or
value-dated books that v1 cannot represent; the proposed v1.1 fields remain unimplemented pending
agreement with Bahi. The unchanged four-query C/R/F corpus remains the cross-engine release gate.

## 10. SAP Business One migration export
The enterprise surface produces verified, balanced SAP Business One DTW ZIP packages for an entity,
office, or same-currency consolidated group: OACT/OCRD/OJDT/JDT1 templates, Folio crosswalks, source
event hashes, and a SHA-256 manifest. Operators must still validate the files against templates
generated by the exact target SAP B1 version before import.

## 11. Non-goals
- Not a Bahi replacement — Bahi stays local-first, standalone, India-first.
- Not RANE (risk-intel SaaS — different domain); reuse its multi-tenant/auth substrate patterns,
  don't rebuild, and don't fold accounting into it.
- No CRDT / E2EE-relay / offline-merge machinery — the server is authoritative. `.khata` exports
  provide portable offline copies without making them a merge substrate.

## 12. Performance baseline

`bin/performance-baseline` is a journal-only rollback microbenchmark. It is useful for local
comparisons, but deliberately excludes transaction commit/fsync cost and is not a production-load
claim. `bin/release-baseline` instead commits a mixed workload of journals, GST invoices, purchase
bills, receipts, and payments, retaining the generated tenant for inspection. It refuses to run
unless the database name contains `performance` or `release_baseline` and
`FOLIO_PERF_COMMITTED_CONFIRM` exactly matches that name.

Both modes fail unless the event chain verifies and the semantic projection plus all measured
reports are identical after rebuild. Adjust volume with `FOLIO_PERF_ENTRIES` and repetitions with
`FOLIO_PERF_REPORT_RUNS`; optional median budgets use names from the JSON, such as
`FOLIO_PERF_BUDGET_REPORTS_DAY_BOOK_MS=500`.

```sh
createdb folio_release_baseline_YYYYMMDD
DATABASE_URL=postgresql:///folio_release_baseline_YYYYMMDD bin/rails db:prepare
DATABASE_URL=postgresql:///folio_release_baseline_YYYYMMDD \
  FOLIO_PERF_COMMITTED_CONFIRM=folio_release_baseline_YYYYMMDD \
  FOLIO_PERF_ENTRIES=250 bin/release-baseline
```

## 13. Product status and roadmap

The current checkpoint includes the governed ledger, India B2B sales/purchases and linked
adjustments, cash settlement/correction, current-state ageing and party ledgers, GST day book and
filing JSON, credit-event/GST-exclusive TDS, period controls, tenant-wide RBAC, replay recovery, and
browser/API flows. INV-01 v1.1 requests, IRP acknowledgement artifacts, and the governed IRN
cancellation/reconciliation boundary have a persistent provider seam. Live IRP/GSP calls remain
deliberately disabled until a provider, credentials, and sandbox certification are approved; an
offline export is never presented as an IRN. The launch image, shared cache, readiness checks,
backup verifier, and Cloudflare Tunnel topology are prepared. Real host/mail/provider values and a
trusted deployed-origin acceptance run remain operator activation gates. Contract management and
the buildable Batch 9 enterprise/full-suite scope are complete. The next jurisdiction remains blocked
on Netcore's actual country list and the approved cross-currency consolidation policy; no profile is
guessed to make the roadmap look complete.

## 14. Open questions
1. Final **name** (Folio vs Abacus / Comptoir / Ledgerline).
2. **Repo shape** — monorepo (Bahi + Folio + shared corpus package, keeps corpus authoritative) vs
   separate repos sharing a published corpus package. Leaning a shared `khata-conformance`
   repo/package both depend on (Bahi is its own repo today).
3. **Launch host/provider** — the Docker image and Cloudflare Tunnel topology are fixed; select the
   real origin host, public hostname, and operational owner.
4. **Managed billing** model + tenant provisioning.

## 15. Production configuration

Production boots only with an explicit public host, sender, and SMTP account; placeholder delivery
is not accepted. Configure these environment variables through the deployment secret store:

- One Rails signing strategy: `RAILS_MASTER_KEY` for encrypted credentials containing
  `secret_key_base`, or a generated `SECRET_KEY_BASE`. Never reuse development/test values.
- Database topology: either all of `DATABASE_URL`, `QUEUE_DATABASE_URL`, and `CACHE_DATABASE_URL`
  naming three distinct PostgreSQL databases, or `FOLIO_DATABASE_PASSWORD` with the configured
  `folio_production`, `folio_production_queue`, and `folio_production_cache` databases/users. The web
  and worker processes need the same signing secret.
- `FOLIO_APP_HOST` — public hostname only, without a scheme.
- `FOLIO_MAIL_FROM` — verified sender address.
- `FOLIO_SMTP_ADDRESS`, `FOLIO_SMTP_USERNAME`, `FOLIO_SMTP_PASSWORD` — provider connection.
- Optional: `FOLIO_SMTP_PORT` (default `587`), `FOLIO_SMTP_DOMAIN`,
  `FOLIO_SMTP_AUTHENTICATION`, and SMTP open/read timeouts.
- Optional: `FOLIO_ALLOWED_HOSTS` — comma-separated exact hostnames; defaults to `FOLIO_APP_HOST`.

Production forces HTTPS/HSTS and secure cookies behind its trusted TLS proxy. Mail jobs use the
durable Solid Queue database; run `bin/jobs` as a worker, or set `SOLID_QUEUE_IN_PUMA=1` for a
single-server deployment. SMTP submission requires STARTTLS and peer verification; a relay that
does not advertise STARTTLS fails before authentication.

Folio does not currently ship an attachment surface. Production uses Solid Cache in its own shared
PostgreSQL database; signup, verification, invitation, and recovery throttles therefore remain
consistent across web processes.

Prepare and smoke-test all databases before booting the web or worker processes:

```sh
RAILS_ENV=production bin/rails db:prepare
RAILS_ENV=production bin/production-check
```

Configure the reverse proxy/access logger to omit query strings or redact the `token` parameter.
Rails filters token query parameters, and verification/invitation/reset tokens are deliberately no
longer embedded in path segments, but an upstream proxy must apply the same rule. Start the web
process only after `db:prepare`; start `bin/jobs`, then exercise `/up`, signup, invitation, password
reset, and one worker restart against the deployed mail provider.

The full topology, deploy order, backup/restore policy, monitoring signals, and activation gates are
in [`docs/production-launch.md`](docs/production-launch.md). The disabled-by-default IRP/GSP contract
and cancellation rules are in [`docs/irp-adapter-contract.md`](docs/irp-adapter-contract.md).

---

## Context
Spun out of the Bahi planning session (2026-07-16). Owner's call: keep Bahi single-office local-first
by design; build multi-user/office/RBAC as this separate server edition. Companion plans live in the
Bahi repo under `plan/2026-07-16-*` (two-product split, multi-office, SAP B1, accounting standards).
