# Folio — the server edition of Bahi

> *A Bahi is one merchant's ledger book. A Folio keeps the firm's accounts across every office.*

**Folio** is the **client-server, multi-user, multi-office** edition of
[Bahi](https://bahi.naklitechie.com/). Bahi stays single-office, local-first, single-file **by
design**; Folio is the team/enterprise tier that reuses Bahi's accounting engine and `.khata` open
format on an authoritative server with real RBAC — built for **global, multi-jurisdiction** scope.

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
- **Local→server upgrade with no lock-in:** a firm starts on Bahi (one office, one file), grows,
  imports the same `.khata` into Folio for team + multi-office; Folio exports per-office `.khata`
  back out (offline/audit/SAP). Same open format both ways — an on-ramp Zoho/QuickBooks can't match.

## 2. The load-bearing principle: a shared CONFORMANCE CONTRACT, not forked code
Folio does **not** fork Bahi's HTML. The shared asset is the **engine semantics + `.khata` format**,
made concrete as a contract Folio's Rails engine is tested against:
- **`.khata` / khata-standard format spec** — already an open standard.
- **Bahi's deterministic test corpus** (53 tests, 3 realistic sample files: pharma / manufacturing /
  consulting) → promoted to a **standalone cross-implementation conformance package**. Folio's Ruby
  posting/GST/reports engine must reproduce it **byte-for-byte**. This corpus is the anti-drift
  guardrail on the most correctness-critical logic in the system.
- **First build step (M0):** extract that corpus + spec into a versioned conformance package both
  Bahi (JS) and Folio (Ruby) run against in CI.

## 3. Tech & topology (decided)
- **Rails 8 + Postgres** — the proven multi-tenant playbook (Trellis / Herald / Muster / Docket).
- **Multi-tenant from day one** — because hosting is **both self-hostable AND managed SaaS in
  parallel**. Self-host = the same app run single-tenant ("your server"); managed = many tenants,
  tenant-scoping always on. One codebase, two deploy topologies.
- **`schema_format = :sql`** (Herald lesson — Postgres features need the SQL schema dumper).
- Engine in **plain Ruby POROs / service objects** (portable, unit-testable against the corpus),
  Rails for the shell (auth, tenancy, RBAC, jobs, API).

## 4. Data model — event-sourced, mirroring Bahi
Bahi is already event-sourced: the signed append-only **audit log is the source of truth**; the
SQLite ledger is a projection. Folio keeps that shape, server-side:
- **`ledger_events`** (append-only, per-tenant) — the authoritative signed event store; the Postgres
  analogue of Bahi's `audit_log` (hash-chained + per-user ECDSA signature + actor + origin).
- **Projection tables** — `accounts`, `entries`, `entry_lines`, `customers`, `vendors`, `items`,
  `invoices`, `purchases`, … materialized from events (same schema families as Bahi, integer paise /
  minor units).
- **Rebuild-from-events** — the same replay guarantee Bahi has (`replayAuditLogToFreshDb`), now the
  routine recovery + read-model rebuild path.
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
- **Auth** — email/password + TOTP; SSO (Google/Microsoft) for the managed tier; self-host can use
  local auth only. (Follow the RANE/Trellis auth pattern; don't rebuild.)
- **Per-user signing keys** enrolled per tenant → every event carries a real user signature →
  non-repudiation, same as Bahi's audit chain but with real identities.

## 6. RBAC (the headline feature)
Roles scoped **per office** (a user can hold different roles in different offices):
| Role | Capabilities |
|---|---|
| **Owner/Admin** | everything + manage users/roles/offices/keys/billing |
| **Accountant** | post/edit vouchers, masters, reports within assigned offices |
| **Operator** | create invoices/receipts/payments in ONE office; no COA/master edits; no period close |
| **CA / Auditor** | cross-office read + adjustment journals + period lock; no master edits |
| **Viewer** | read-only (reports, ledgers) |

Capability checks server-side on every mutation; the signed event log makes every action
attributable and provable.

## 7. Multi-office / multi-entity
The **unified `office` entity** (from Bahi's multi-office plan) lives here:
- An office carries: GSTIN (or jurisdiction tax id), its own **prefixed voucher series** (disjoint →
  concurrent numbering never collides), default bank/cash accounts, default place-of-supply,
  assigned users+roles.
- Two shapes under one model: **separate-tax-id offices** (own books + **consolidation view**) and
  **single-tax-id branches** (office_id dimension on entries/invoices).
- **Consolidation** = group-by office over the tenant's ledger → group P&L/BS; also the unit that
  feeds the SAP export. Cross-jurisdiction consolidation needs a reporting-currency policy (later).

## 8. Jurisdiction profiles / accounting standards
The `JurisdictionProfile` work (COA template + statement presentation + terminology + tax adapter +
currency + FY convention) is more an enterprise/multi-entity concern → **lands primarily in Folio**
(Bahi can stay India-first). Profiles: IN-IGAAP, IN-INDAS, UK-FRS102, MY-MPERS, SG-SFRS, US-GAAP,
NG-IFRS. Tax-adapter abstraction (GST↔VAT↔SST↔sales-tax) is the deep refactor and is server-side.
Cross-ref: `bahi/plan/2026-07-16-accounting-standards-multi-jurisdiction.md`.

## 9. Interop bridge (Bahi ↔ Folio) — first-class, not an afterthought
- **Import `.khata` → Folio**: parse the zip → replay its signed audit log into `ledger_events` for
  a tenant/office (idempotent by event hash). The on-ramp.
- **Export office → `.khata`**: materialize an office's events + projection into a valid `.khata`
  zip (offline copy, audit handoff, or SAP feed). Round-trips against the conformance corpus.

## 10. SAP B1 (HANA) export
The DTW export (COA crosswalk + `oJournalEntries`/documents) specced for Bahi
(`bahi/plan/2026-07-16-sap-b1-hana-mapping-spec.md`) is naturally an enterprise feature → shared
engine logic, surfaced in Folio per-office / consolidated. Build once in the shared engine layer.

## 11. Non-goals
- Not a Bahi replacement — Bahi stays local-first, standalone, India-first.
- Not RANE (risk-intel SaaS — different domain); reuse its multi-tenant/auth substrate patterns,
  don't rebuild, and don't fold accounting into it.
- No CRDT / E2EE-relay / offline-merge machinery — the server is authoritative (Folio is online;
  offline copies are `.khata` exports, handled by the bridge).

## 12. Milestones
- **M0 — Conformance package (keystone).** Extract `.khata` spec + Bahi's 53-test corpus into a
  versioned package; CI harness that runs an engine impl against it. Nothing else starts until the
  contract is executable.
- **M1 — Engine parity in Ruby.** Port the double-entry + GST posting core to Ruby service objects;
  green against the corpus. Event store + projection + rebuild.
- **M2 — Tenancy + auth + RBAC spine.** Explicit application-level tenant scoping, users, per-office roles,
  capability gating, signed events with real user keys.
- **M3 — Office model + core workflows.** Offices, prefixed series, invoices/purchases/payments,
  reports (TB/BS/P&L/CF), period lock.
- **M4 — Interop bridge.** `.khata` import (on-ramp) + per-office export; round-trip vs corpus.
- **M5 — Consolidation + jurisdiction profiles (phase 1: IGAAP/Ind-AS).**
- **M6 — SAP DTW export + managed-tier hardening** (billing, backups, self-host packaging).

## 13. Open questions
1. Final **name** (Folio vs Abacus / Comptoir / Ledgerline).
2. **Repo shape** — monorepo (Bahi + Folio + shared corpus package, keeps corpus authoritative) vs
   separate repos sharing a published corpus package. Leaning a shared `khata-conformance`
   repo/package both depend on (Bahi is its own repo today).
3. **Self-host packaging** — Docker Compose vs single-binary-ish; how far to go for v1.
4. **Managed billing** model + tenant provisioning.

## 14. Production configuration

Production boots only with an explicit public host, sender, and SMTP account; placeholder delivery
is not accepted. Configure these environment variables through the deployment secret store:

- `FOLIO_APP_HOST` — public hostname only, without a scheme.
- `FOLIO_MAIL_FROM` — verified sender address.
- `FOLIO_SMTP_ADDRESS`, `FOLIO_SMTP_USERNAME`, `FOLIO_SMTP_PASSWORD` — provider connection.
- Optional: `FOLIO_SMTP_PORT` (default `587`), `FOLIO_SMTP_DOMAIN`,
  `FOLIO_SMTP_AUTHENTICATION`, and SMTP open/read timeouts.
- Optional: `FOLIO_ALLOWED_HOSTS` — comma-separated exact hostnames; defaults to `FOLIO_APP_HOST`.

Production forces HTTPS/HSTS and secure cookies behind its trusted TLS proxy. Mail jobs use the
durable Solid Queue database; run `bin/jobs` as a worker, or set `SOLID_QUEUE_IN_PUMA=1` for a
single-server deployment. Prepare the primary and queue databases before booting the app.

---

## Context
Spun out of the Bahi planning session (2026-07-16). Owner's call: keep Bahi single-office local-first
by design; build multi-user/office/RBAC as this separate server edition. Companion plans live in the
Bahi repo under `plan/2026-07-16-*` (two-product split, multi-office, SAP B1, accounting standards).
