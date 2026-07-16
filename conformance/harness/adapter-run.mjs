// Shared helper: invoke an engine adapter for one (query, case-file) and return its stdout string.
// The adapter command is a shell-style token list (e.g. "node adapters/js/adapter.mjs" or
// "ruby adapters/ruby/adapter.rb"); we append [query, khataPath] and spawn it from the package root.

import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..'); // conformance/

export function parseAdapterArg(argv) {
  const i = argv.indexOf('--adapter');
  const cmd = i >= 0 && argv[i + 1] ? argv[i + 1] : 'node adapters/js/adapter.mjs';
  return cmd.trim().split(/\s+/);
}

export function runAdapter(adapterTokens, query, khataRelPath) {
  const [bin, ...rest] = adapterTokens;
  const res = spawnSync(bin, [...rest, query, khataRelPath], {
    cwd: ROOT,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  });
  if (res.status !== 0) {
    throw new Error(
      `adapter failed (exit ${res.status}) for query='${query}' file='${khataRelPath}'\n${res.stderr || ''}`
    );
  }
  return res.stdout;
}
