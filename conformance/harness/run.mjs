#!/usr/bin/env node
// Tier C + Tier R conformance runner — byte-for-byte.
//
//   node harness/run.mjs [--adapter '<cmd>']     (default: node adapters/js/adapter.mjs)
//
// Tier C — for every case, the adapter's `verify-chain` MUST report ok:true, zero bad rows, and the
//          exact audit row count pinned in the manifest. This proves the engine reproduces Bahi's
//          canonicalJson + audit-hash bytes for every row.
// Tier R — for every (case, report query), the adapter's stdout MUST be byte-identical to the
//          committed golden fixture. This proves the engine reproduces Bahi's accounting output.
//
// Exit 0 = fully conformant. Exit 1 = at least one divergence (details printed).

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT, parseAdapterArg, runAdapter } from './adapter-run.mjs';

const adapter = parseAdapterArg(process.argv);
const manifest = JSON.parse(readFileSync(join(ROOT, 'corpus/manifest.json'), 'utf8'));

let total = 0;
let passed = 0;
const failures = [];

function applies(appliesTo, id) {
  return appliesTo.includes('*') || appliesTo.includes(id);
}

// ── Tier C — canonicalisation + audit chain ────────────────────────────────
const tierC = manifest.tiers.C;
for (const c of manifest.cases) {
  if (!applies(tierC.appliesTo, c.id)) continue;
  total++;
  try {
    const out = runAdapter(adapter, tierC.query, join('corpus', c.file));
    const r = JSON.parse(out);
    const problems = [];
    if (r.ok !== true) problems.push(`ok=${r.ok}`);
    if (Array.isArray(r.badRows) && r.badRows.length > 0) problems.push(`badRows=${JSON.stringify(r.badRows.slice(0, 2))}`);
    if (typeof c.auditRows === 'number' && r.count !== c.auditRows) problems.push(`count=${r.count} expected ${c.auditRows}`);
    if (problems.length === 0) passed++;
    else failures.push(['C', c.id, tierC.query, problems.join('; ')]);
  } catch (e) {
    failures.push(['C', c.id, tierC.query, e.message]);
  }
}

// ── Tier R — report golden outputs (byte-for-byte) ─────────────────────────
const tierR = manifest.tiers.R;
for (const c of manifest.cases) {
  for (const q of tierR.queries) {
    if (!applies(q.appliesTo, c.id)) continue;
    total++;
    const fixtureRel = tierR.fixturePath.replace('{case}', c.id).replace('{query}', q.name);
    try {
      const got = runAdapter(adapter, q.name, join('corpus', c.file));
      let want;
      try {
        want = readFileSync(join(ROOT, 'corpus', fixtureRel), 'utf8');
      } catch {
        failures.push(['R', c.id, q.name, `missing golden fixture ${fixtureRel} — run: npm run gen-fixtures`]);
        continue;
      }
      if (Buffer.compare(Buffer.from(got), Buffer.from(want)) === 0) {
        passed++;
      } else {
        failures.push(['R', c.id, q.name, firstDiff(want, got, fixtureRel)]);
      }
    } catch (e) {
      failures.push(['R', c.id, q.name, e.message]);
    }
  }
}

function firstDiff(want, got, fixtureRel) {
  let i = 0;
  const n = Math.min(want.length, got.length);
  while (i < n && want[i] === got[i]) i++;
  const ctx = (s) => JSON.stringify(s.slice(Math.max(0, i - 20), i + 40));
  return `byte-for-byte mismatch vs ${fixtureRel} at offset ${i} (len want=${want.length} got=${got.length})\n      want …${ctx(want)}\n      got  …${ctx(got)}`;
}

// ── Report ─────────────────────────────────────────────────────────────────
console.log(`Tier C + R — engine conformance via [${adapter.join(' ')}]: ${passed}/${total} checks passed`);
if (failures.length) {
  console.log(`\n${failures.length} FAILED:`);
  for (const [tier, cid, q, detail] of failures) {
    console.log(`  ✗ [${tier}] ${cid} / ${q}\n      ${detail}`);
  }
  process.exit(1);
}
console.log('  ✓ audit chains reproduce byte-for-byte; all reports match golden');
