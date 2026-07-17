#!/usr/bin/env ruby
# frozen_string_literal: true

# Reference engine adapter #2 — Ruby. Proves the conformance contract with a SECOND implementation
# held to the same corpus as the JS adapter, byte-for-byte. This is the shape Folio's Rails engine
# will expose at M1.
#
#   ruby adapter.rb <query> <path-to.khata>   ->   canonical JSON on stdout, exit 0
#
# Reads the .khata's books.sqlite (extracted via the `unzip` CLI) with the sqlite3 gem, and answers
# the language-neutral adapter queries (see ../README.md and ../../corpus/manifest.json). The
# audit-chain verifier reuses the byte contract in canonical_json.rb VERBATIM — the parity anchor.
# Portable across Ruby 2.6 → 3.x.

require 'sqlite3'
require 'tempfile'
require_relative 'canonical_json'

module KhataAdapter
  module_function

  def open_books(khata_path)
    tmp = Tempfile.new(['khata-conf', '.sqlite'])
    tmp.close
    unless system('unzip', '-p', khata_path, 'books.sqlite', out: tmp.path)
      raise "unzip failed to extract books.sqlite from #{khata_path}"
    end
    db = SQLite3::Database.new(tmp.path)
    db.results_as_hash = true
    [db, tmp]
  end

  # ── Tier C — canonicalisation + audit chain ────────────────────────────────
  def verify_chain(db)
    rows = db.execute(
      'SELECT id, ts, actor, action, ref, origin, payload, prev_hash, hash, hash_version ' \
      'FROM audit_log ORDER BY id'
    )
    prev = KhataCanonical::GENESIS_PREV
    bad = []
    rows.each do |r|
      genesis_ok = prev == KhataCanonical::GENESIS_PREV &&
                   (r['prev_hash'] == '' || r['prev_hash'].nil? || r['prev_hash'] == KhataCanonical::GENESIS_PREV)
      if r['prev_hash'] != prev && !genesis_ok
        bad << { 'id' => r['id'], 'reason' => 'chain-link', 'got' => r['prev_hash'], 'want' => prev }
        prev = r['hash']
        next
      end
      computed = KhataCanonical.row_hash(r)
      if computed != r['hash']
        bad << { 'id' => r['id'], 'reason' => 'hash-mismatch', 'computed' => computed, 'stored' => r['hash'] }
      end
      prev = r['hash']
    end
    { 'ok' => bad.empty?, 'count' => rows.length, 'badRows' => bad.first(10) }
  end

  QUERIES = {
    'verify-chain' => method(:verify_chain)
  }.freeze

  def run(argv)
    query, khata_path = argv
    unless query && khata_path && QUERIES.key?(query)
      warn "usage: adapter.rb <#{QUERIES.keys.join('|')}> <file.khata>"
      exit 2
    end
    db, tmp = open_books(khata_path)
    begin
      result = QUERIES[query].call(db)
      $stdout.write(KhataCanonical.canonical_json(result) + "\n")
    ensure
      db.close
      tmp.unlink
    end
  end
end

KhataAdapter.run(ARGV) if $PROGRAM_NAME == __FILE__
