# frozen_string_literal: true

require "test_helper"
require "sqlite3"
require "tempfile"
require "json"

# Tier C, run through Posting::PostEntry.ingest_verbatim! — the replay-INGESTION path that
# the M4 .khata bridge will use. This proves the new posting engine's own entry point
# stores an existing chain verbatim and reproduces the pinned auditHead for ALL three
# corpus files, not just via the standalone adapter (which the harness already covers) and
# not just via a raw insert (tier_c_through_rails_test covers that).
#
# The corpus events are Bahi's THIN summaries (e.g. entry.post carries totals, not lines),
# so replay! projects no line detail for them — but the chain still reproduces, which is
# the Tier C claim. Fat-event replay purity is proven in Posting::PostEntryTest.
#
# Nothing here writes to conformance/; the corpus is opened read-only.
class TierCThroughPostEntryTest < ActiveSupport::TestCase
  CONFORMANCE = Rails.root.join("conformance")
  MANIFEST = JSON.parse(File.read(CONFORMANCE.join("corpus/manifest.json")))

  test "every corpus chain reproduces its pinned auditHead when ingested through PostEntry" do
    MANIFEST["cases"].each_with_index do |kase, idx|
      tenant_id = 8_100 + idx
      rows = audit_rows(kase["file"])

      Posting::PostEntry.ingest_verbatim!(tenant_id: tenant_id, rows: rows)

      assert_equal kase["auditRows"], LedgerEvent.for_tenant(tenant_id).count,
        "#{kase['id']}: stored row count drifted from the pinned manifest"

      result = LedgerEvent.verify_chain(tenant_id)
      assert result[:ok], "#{kase['id']}: chain broke at seq=#{result[:broken_at]} (#{result[:reason]})"
      assert_equal kase["auditRows"], result[:rows]
      assert_equal kase["auditHead"], result[:head],
        "#{kase['id']}: head from the PostEntry-ingested chain must equal the pinned auditHead"
    end
  end

  private

  def audit_rows(relative_path)
    path = CONFORMANCE.join("corpus", relative_path)
    tmp = Tempfile.new([ "khata-post", ".sqlite" ])
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
