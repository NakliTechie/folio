#!/usr/bin/env node
// (Re)generate Tier R golden fixtures from an engine adapter (default: the JS reference adapter).
// Run this ONLY when an output change is intentional — the committed fixtures are the golden that
// run.mjs asserts against, so regenerating is equivalent to blessing new expected output.
//
//   node harness/gen-fixtures.mjs [--adapter '<cmd>']

import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT, parseAdapterArg, runAdapter } from './adapter-run.mjs';

const adapter = parseAdapterArg(process.argv);
const manifest = JSON.parse(readFileSync(join(ROOT, 'corpus/manifest.json'), 'utf8'));
const queries = manifest.tiers.R.queries;

let written = 0;
for (const c of manifest.cases) {
  const dir = join(ROOT, 'corpus/fixtures', c.id);
  mkdirSync(dir, { recursive: true });
  for (const q of queries) {
    if (!(q.appliesTo.includes('*') || q.appliesTo.includes(c.id))) continue;
    const out = runAdapter(adapter, q.name, join('corpus', c.file));
    writeFileSync(join(dir, `${q.name}.json`), out);
    written++;
    console.log(`  wrote corpus/fixtures/${c.id}/${q.name}.json (${out.length} bytes)`);
  }
}
console.log(`gen-fixtures: ${written} golden fixtures written via [${adapter.join(' ')}]`);
