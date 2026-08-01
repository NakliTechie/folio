# frozen_string_literal: true

require "test_helper"
require "sqlite3"
require "tempfile"
require "json"

# Tier C, run THROUGH THE RAILS ENGINE rather than through the standalone adapter.
#
# The conformance harness already proves the adapter reproduces these chains. That is
# not the same claim as "Folio's application code reproduces them" — the adapter is a
# 131-line script, the app is a different loading path, a different Ruby, and (once
# events are stored) a different source of bytes. This test closes that gap, and it is
# the gate the night's plan named for Batch 2.
#
# Nothing here writes to conformance/; the corpus is opened read-only.
class TierCThroughRailsTest < ActiveSupport::TestCase
  CONFORMANCE = Rails.root.join("conformance")
  MANIFEST = JSON.parse(File.read(CONFORMANCE.join("corpus/manifest.json")))

  test "every corpus chain reproduces its pinned auditHead through Folio::KhataHash" do
    MANIFEST["cases"].each do |kase|
      rows = audit_rows(kase["file"])

      assert_equal kase["auditRows"], rows.length,
        "#{kase['id']}: row count drifted from the pinned manifest"

      # Two distinct assertions, exactly as the reference adapter makes them: the hash
      # is recomputed from the row's OWN stored prev_hash, while linkage separately
      # checks that stored prev_hash equals the running head (with genesis tolerance).
      prev = Folio::KhataHash::GENESIS_PREV
      rows.each do |r|
        genesis_ok = prev == Folio::KhataHash::GENESIS_PREV &&
                     (r["prev_hash"].to_s.empty? || r["prev_hash"] == Folio::KhataHash::GENESIS_PREV)
        assert(r["prev_hash"] == prev || genesis_ok,
          "#{kase['id']}: chain link broke at audit_log id=#{r['id']}")

        assert_equal r["hash"], Folio::KhataHash.row_hash(r),
          "#{kase['id']}: hash mismatch at audit_log id=#{r['id']}"
        prev = r["hash"]
      end

      assert_equal kase["auditHead"], prev,
        "#{kase['id']}: final head does not match the pinned auditHead"
    end
  end

  test "an ingested chain verifies from ledger_events, not just from the source rows" do
    # consulting is the smallest corpus case (1029 rows) — enough to prove the store
    # round-trips without making the suite slow.
    kase = MANIFEST["cases"].find { |c| c["id"] == "consulting" }
    rows = audit_rows(kase["file"])
    tenant_id = 9_001

    # Replaying an existing chain preserves its hashes verbatim; append! is for NEW
    # events. The product bridge now uses this same byte-preserving path after archive verification.
    now = Time.now.utc
    LedgerEvent.insert_all!(
      rows.each_with_index.map do |r, i|
        {
          tenant_id: tenant_id, seq: i + 1,
          # Verbatim — the stored prev_hash is what went into this row's preimage.
          # Normalising '' to 64 zeros here would silently invalidate the hash.
          prev_hash: r["prev_hash"].to_s,
          hash_hex: r["hash"], hash_version: r["hash_version"] || 2,
          ts: r["ts"], actor: r["actor"], action: r["action"],
          ref: r["ref"], origin: r["origin"], payload: r["payload"],
          recorded_at: now
        }
      end
    )

    assert_equal kase["auditRows"], LedgerEvent.for_tenant(tenant_id).count

    result = LedgerEvent.verify_chain(tenant_id)
    assert result[:ok], "chain broke at seq=#{result[:broken_at]}"
    assert_equal kase["auditRows"], result[:rows]
    assert_equal kase["auditHead"], result[:head],
      "head from ledger_events must equal the pinned auditHead"
  end

  test "ActiveSupport JSON escaping stays off — it silently forks the chain" do
    # Regression guard for config/initializers/khata_byte_contract.rb. With Rails'
    # default escape_html_entities_in_json = true, '&' encodes as & and every
    # event whose payload contains & < or > hashes differently from Bahi. It first
    # bit on a real corpus name, "Health & Glow Pharmacy".
    assert_not ActiveSupport.escape_html_entities_in_json,
      "escape_html_entities_in_json must stay false — see khata_byte_contract.rb"

    payload = Folio::KhataHash.canonical_payload({ "name" => "Health & Glow Pharmacy" })
    assert_equal '{"name":"Health & Glow Pharmacy"}', payload
    # The literal ampersand belongs there; the escaped form is what breaks parity.
    assert_not_includes payload, "u0026", "ampersand must not be \\u-escaped"
  end

  private

  def audit_rows(relative_path)
    path = CONFORMANCE.join("corpus", relative_path)
    tmp = Tempfile.new([ "khata-rails", ".sqlite" ])
    tmp.close
    raise "unzip failed for #{path}" unless
      system("unzip", "-p", path.to_s, "books.sqlite", out: tmp.path)

    db = SQLite3::Database.new(tmp.path)
    db.results_as_hash = true
    db.execute(
      "SELECT id, ts, actor, action, ref, origin, payload, prev_hash, hash, hash_version " \
      "FROM audit_log ORDER BY id"
    )
  ensure
    db&.close
    tmp&.unlink
  end
end
