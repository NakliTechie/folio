# Folio — governed accounting for service businesses

> *A Bahi is one merchant's ledger book. A Folio is the governed server ledger for a team.*

**Folio** is a multi-user Rails/Postgres accounting application for India services-first businesses.
The current product operates one primary office per company with tenant-wide role assignments. It
supports governed masters, sales and purchase documents, receipts/payments, open-item settlement,
credit-event TDS, filing JSON for GSTR-1/GSTR-3B/CMP-08, offline INV-01 e-invoice preparation,
period controls, and append-only hash-chained financial and lifecycle event logs.

Folio shares accounting semantics and a conformance corpus with
[Bahi](https://bahi.naklitechie.com/), which remains single-office, local-first, and single-file by
design. Multi-office operation, more jurisdictions, signed user events, and the full `.khata` bridge
are roadmap work—not current product claims.

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
- **Planned local→server upgrade without lock-in:** the target is a full `.khata` event import and
  export bridge. Today Folio has a projection-only, test/conformance importer; it is not yet a product
  migration or export surface.

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
  hash-chained and carry actor/origin labels. Per-user cryptographic signatures and non-repudiation
  are not implemented yet; the signature field is reserved for that future key lifecycle.
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
- **Signing later** — per-user signing-key enrollment, verification, rotation, and recovery must ship
  together before Folio can claim cryptographic attribution or non-repudiation.

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
| **Viewer** | read-only (reports, ledgers) |

Capability checks run server-side. Posted entries freeze the resolved role/limit authority; the event
log is hash-chained but not yet cryptographically signed by the user.

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

Today, a thin test adapter imports `.khata` projection tables to prove account-report compatibility
against the vendored corpus. It does not import the authoritative chain, expose a UI/API, resolve
conflicts, or export files. The roadmap bridge will add idempotent event import plus `.khata` export
and round-trip verification.

## 10. Planned SAP B1 (HANA) export
The DTW export (COA crosswalk + `oJournalEntries`/documents) specced for Bahi
(`bahi/plan/2026-07-16-sap-b1-hana-mapping-spec.md`) is naturally an enterprise feature → shared
engine logic, surfaced in Folio per-office / consolidated. Build once in the shared engine layer.

## 11. Non-goals
- Not a Bahi replacement — Bahi stays local-first, standalone, India-first.
- Not RANE (risk-intel SaaS — different domain); reuse its multi-tenant/auth substrate patterns,
  don't rebuild, and don't fold accounting into it.
- No CRDT / E2EE-relay / offline-merge machinery — the server is authoritative. Planned `.khata`
  exports will provide portable offline copies without making them a merge substrate.

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
browser/API flows. INV-01 v1.1 requests and IRP acknowledgement artifacts have a persistent provider
seam, but live IRP/GSP submission is deliberately disabled until a provider and credentials are
chosen; an offline export is never presented as an IRN. The remaining sequence is production launch,
contract management, full-suite accounting, multi-office/multi-country depth, and the complete
`.khata` bridge.

## 14. Open questions
1. Final **name** (Folio vs Abacus / Comptoir / Ledgerline).
2. **Repo shape** — monorepo (Bahi + Folio + shared corpus package, keeps corpus authoritative) vs
   separate repos sharing a published corpus package. Leaning a shared `khata-conformance`
   repo/package both depend on (Bahi is its own repo today).
3. **Self-host packaging** — Docker Compose vs single-binary-ish; how far to go for v1.
4. **Managed billing** model + tenant provisioning.

## 15. Production configuration

Production boots only with an explicit public host, sender, and SMTP account; placeholder delivery
is not accepted. Configure these environment variables through the deployment secret store:

- One Rails signing strategy: `RAILS_MASTER_KEY` for encrypted credentials containing
  `secret_key_base`, or a generated `SECRET_KEY_BASE`. Never reuse development/test values.
- Database topology: either `DATABASE_URL` and `QUEUE_DATABASE_URL`, or
  `FOLIO_DATABASE_PASSWORD` with the configured `folio_production` and `folio_production_queue`
  databases/users. The web and worker processes need the same signing secret.
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

Folio does not currently ship an attachment surface or a shared Rails cache. Active Storage and
unused Solid Cache scaffolding are intentionally absent. Before a multi-process launch, choose and
verify the shared rate-limit/cache topology recorded in the roadmap decision queue.

Prepare and smoke-test all databases before booting the web or worker processes:

```sh
RAILS_ENV=production bin/rails db:prepare
RAILS_ENV=production bin/rails runner 'puts Rails.application.config.x.mail_from'
RAILS_ENV=production bin/rails runner 'abort "database unavailable" unless LedgerEvent.limit(1).count >= 0'
```

Configure the reverse proxy/access logger to omit query strings or redact the `token` parameter.
Rails filters token query parameters, and verification/invitation/reset tokens are deliberately no
longer embedded in path segments, but an upstream proxy must apply the same rule. Start the web
process only after `db:prepare`; start `bin/jobs`, then exercise `/up`, signup, invitation, password
reset, and one worker restart against the deployed mail provider.

---

## Context
Spun out of the Bahi planning session (2026-07-16). Owner's call: keep Bahi single-office local-first
by design; build multi-user/office/RBAC as this separate server edition. Companion plans live in the
Bahi repo under `plan/2026-07-16-*` (two-product split, multi-office, SAP B1, accounting standards).
