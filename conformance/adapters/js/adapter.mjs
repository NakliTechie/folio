#!/usr/bin/env node
// Reference engine adapter — the FIRST conforming implementation, using Bahi's engine semantics.
//
//   node adapter.mjs <query> <path-to.khata>   ->   canonical JSON on stdout, exit 0
//
// It uses Node 22's built-in node:sqlite (zero native deps, no npm install), reads the .khata's
// books.sqlite, and answers the language-neutral adapter queries (see ../README.md and
// ../../corpus/manifest.json). Tiers C and R of the harness run through this contract; Folio's
// future Ruby adapter implements the same CLI and must produce byte-identical output.
//
// The audit-chain verifier reuses Bahi's canonicalJson/auditPreimageV2 VERBATIM (canonical-json.mjs)
// — the parity anchor. The report queries are plain SQL over the v12 projection tables.

import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { readZipEntry } from './zip.mjs';
import { canonicalJson, rowHash, GENESIS_PREV } from './canonical-json.mjs';

// node:sqlite returns INTEGER columns as BigInt; corpus magnitudes are within Number.MAX_SAFE_INTEGER
// (paise sums < 9e15), so coerce to Number for clean integer JSON. Guard against overflow anyway.
function num(v) {
  if (typeof v === 'bigint') {
    if (v > BigInt(Number.MAX_SAFE_INTEGER) || v < BigInt(Number.MIN_SAFE_INTEGER)) {
      throw new Error(`integer ${v} exceeds safe range — report needs BigInt handling`);
    }
    return Number(v);
  }
  return v;
}

function openBooks(khataPath) {
  const buf = readFileSync(khataPath);
  const books = readZipEntry(buf, 'books.sqlite');
  const tmp = join(tmpdir(), `khata-conf-${randomUUID()}.sqlite`);
  writeFileSync(tmp, books);
  const db = new DatabaseSync(tmp, { readOnly: true });
  return { db, tmp };
}

// ─────────────────────────────────────────────────────── Tier C query ─────

function verifyChain(db) {
  const rows = db
    .prepare('SELECT id, ts, actor, action, ref, origin, payload, prev_hash, hash, hash_version FROM audit_log ORDER BY id')
    .all();
  let prev = GENESIS_PREV;
  const badRows = [];
  for (const r of rows) {
    // Chain link: prev_hash must equal the prior row's hash. Genesis (first row) tolerates
    // '' / null / 0*64 per spec §5.2.
    const genesisOk = prev === GENESIS_PREV && (r.prev_hash === '' || r.prev_hash === null || r.prev_hash === GENESIS_PREV);
    if (r.prev_hash !== prev && !genesisOk) {
      badRows.push({ id: num(r.id), reason: 'chain-link', got: r.prev_hash, want: prev });
      prev = r.hash;
      continue;
    }
    const computed = rowHash(r);
    if (computed !== r.hash) {
      badRows.push({ id: num(r.id), reason: 'hash-mismatch', computed, stored: r.hash });
    }
    prev = r.hash;
  }
  return { ok: badRows.length === 0, count: rows.length, badRows: badRows.slice(0, 10) };
}

// ─────────────────────────────────────────────────────── Tier R queries ─────

function trialBalance(db) {
  const rows = db
    .prepare(
      `SELECT el.account_id AS account_id, a.name AS name, a.type AS type,
              SUM(el.debit) AS debit, SUM(el.credit) AS credit
       FROM entry_lines el JOIN accounts a ON a.id = el.account_id
       GROUP BY el.account_id ORDER BY el.account_id`
    )
    .all();
  return rows.map((r) => ({
    account_id: num(r.account_id),
    name: r.name,
    type: r.type,
    debit: num(r.debit),
    credit: num(r.credit),
  }));
}

function accountTypeTotals(db) {
  const rows = db
    .prepare(
      `SELECT a.type AS type, SUM(el.debit) AS debit, SUM(el.credit) AS credit
       FROM entry_lines el JOIN accounts a ON a.id = el.account_id
       GROUP BY a.type ORDER BY a.type`
    )
    .all();
  return rows.map((r) => ({ type: r.type, debit: num(r.debit), credit: num(r.credit) }));
}

function gstOutwardSummary(db) {
  const r = db
    .prepare(
      `SELECT COUNT(*) AS invoice_count,
              COALESCE(SUM(subtotal),0) AS taxable,
              COALESCE(SUM(cgst),0) AS cgst, COALESCE(SUM(sgst),0) AS sgst,
              COALESCE(SUM(igst),0) AS igst, COALESCE(SUM(cess),0) AS cess
       FROM invoices WHERE status = 'posted'`
    )
    .get();
  return {
    invoice_count: num(r.invoice_count),
    taxable: num(r.taxable),
    cgst: num(r.cgst),
    sgst: num(r.sgst),
    igst: num(r.igst),
    cess: num(r.cess),
  };
}

function stockOnHand(db) {
  const rows = db
    .prepare(
      `SELECT sm.item_id AS item_id, COALESCE(i.name,'') AS item_name,
              SUM(CASE WHEN sm.movement_type='in' THEN sm.qty ELSE -sm.qty END) AS on_hand_qty
       FROM stock_movements sm LEFT JOIN items i ON i.id = sm.item_id
       GROUP BY sm.item_id ORDER BY sm.item_id`
    )
    .all();
  return rows.map((r) => ({
    item_id: num(r.item_id),
    item_name: r.item_name,
    on_hand_qty: num(r.on_hand_qty),
  }));
}

const QUERIES = {
  'verify-chain': verifyChain,
  'trial-balance': trialBalance,
  'account-type-totals': accountTypeTotals,
  'gst-outward-summary': gstOutwardSummary,
  'stock-on-hand': stockOnHand,
};

function main() {
  const [query, khataPath] = process.argv.slice(2);
  if (!query || !khataPath || !QUERIES[query]) {
    process.stderr.write(`usage: adapter.mjs <${Object.keys(QUERIES).join('|')}> <file.khata>\n`);
    process.exit(2);
  }
  const { db, tmp } = openBooks(khataPath);
  try {
    const result = QUERIES[query](db);
    process.stdout.write(canonicalJson(result) + '\n');
  } finally {
    db.close();
    rmSync(tmp, { force: true });
  }
}

main();
