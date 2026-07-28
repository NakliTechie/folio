# frozen_string_literal: true

require "test_helper"
require "json"

# Tier R, THROUGH THE NEW MODEL. The corpus is imported into Folio's projection (Khata::Import),
# then the report queries run over that projection (Reports::*) and must reproduce the golden
# fixtures byte-for-byte — not via the .khata adapter.
#
# Only the two ACCOUNT-based reports are covered here; gst-outward-summary and stock-on-hand
# read Bahi domain tables (invoices, stock_movements) that Folio does not project until Batch 6
# / inventory, so they stay on the adapter for now (see the B3.5 note in the workplan).
#
# Nothing here writes to conformance/; the corpus is opened read-only.
class TierRThroughRailsTest < ActiveSupport::TestCase
  CONFORMANCE = Rails.root.join("conformance")
  MANIFEST = JSON.parse(File.read(CONFORMANCE.join("corpus/manifest.json")))
  QUERIES = { "trial-balance" => :trial_balance, "account-type-totals" => :account_type_totals }.freeze

  def golden(case_id, query)
    File.read(CONFORMANCE.join("corpus/fixtures/#{case_id}/#{query}.json")).strip
  end

  def canonical(data)
    Folio::KhataHash.canonical_payload(data)
  end

  test "every corpus account report reproduces its golden fixture byte-for-byte through the new model" do
    MANIFEST["cases"].each_with_index do |kase, idx|
      tenant = 8_300 + idx
      Khata::Import.import!(khata_path: CONFORMANCE.join("corpus", kase["file"]), tenant_id: tenant)

      QUERIES.each do |query, method|
        assert_equal golden(kase["id"], query), canonical(Reports.public_send(method, tenant)),
          "#{kase['id']}/#{query}: report drifted from the golden fixture through the new model"
      end
    end
  end

  test "the Tier R check is non-vacuous — a 1-paise perturbation breaks the byte match" do
    kase = MANIFEST["cases"].find { |c| c["id"] == "consulting" }
    tenant = 8_399
    Khata::Import.import!(khata_path: CONFORMANCE.join("corpus", kase["file"]), tenant_id: tenant)
    assert_equal golden("consulting", "trial-balance"), canonical(Reports.trial_balance(tenant))

    amt = JournalEntryLineAmount.where(tenant_id: tenant).first
    amt.update!(amount_minor: amt.amount_minor + 1)
    refute_equal golden("consulting", "trial-balance"), canonical(Reports.trial_balance(tenant)),
      "a 1-paise change must break the byte-for-byte match"
  end
end
