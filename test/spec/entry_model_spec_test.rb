# frozen_string_literal: true

require "test_helper"

# The M-lock gate's executable half. These tests assert the schema described by
# plan/spec/entry-model-v1.md. They SKIP by default (see the setup guard below) and
# FAIL when opted in, until Batch 3 builds the schema.
#
# A red suite is the correct outcome of the M-lock run. What matters is that they fail
# for the RIGHT reason — a named missing table or column — not a syntax error or a nil
# crash. So every assertion goes through table_exists? / column_exists?, which return
# false rather than raising: the failure message then names exactly what is absent.
#
# The failing set is a SUBSTANTIAL SUBSET of Batch 3's work, not the whole of it — the
# spec (plan/spec/entry-model-v1.md) carries fields these tests do not yet assert, listed
# in the M-lock report's gap section. Do not treat a green run here as Batch 3 complete.
#
# Two tests marked D15 GUARD are NOT spec stubs: they pass today and guard behaviour the
# whole additive-widening argument rests on.
#
# Each test cites the decision (D-number) that mandates it and, where relevant, the
# owner answer that set its shape. Where the SAP parity matrix and the owner's answers
# of 2026-07-28 differ, the answers win.
class EntryModelSpecTest < ActiveSupport::TestCase
  # These tests assert the schema described by plan/spec/entry-model-v1.md. Per the
  # workplan's CI arc, as each Batch 3 sub-batch lands the tests it satisfies are
  # re-enabled in CI; the ones still owed carry an explicit `skip` naming the sub-batch
  # that will satisfy them — so CI stays green while the debt stays visible and NAMED,
  # not hidden behind an env var. B3.0 + B3.1 have landed, so all but three run here.
  # The old RUN_SPEC_TESTS gate is gone: there is no permanently-red set left to hide.
  # At B3.2 the Posting::PostEntry skip lifts; at B3.4 the period_controls skip lifts;
  # the D13-matrix skip stays until M2. (RUN_SPEC_TESTS is now a no-op if still set.)
  #
  # The D15 GUARD tests are deliberately NOT here — they pass today, guard the Bahi
  # contract, and run in CI. See test/conformance/d15_additive_widening_test.rb.

  def conn = ActiveRecord::Base.connection

  def assert_table(name, decision)
    assert conn.table_exists?(name), "#{decision}: table `#{name}` does not exist yet"
  end

  def assert_columns(table, columns, decision)
    assert conn.table_exists?(table), "#{decision}: table `#{table}` does not exist yet"
    missing = columns.reject { |c| conn.column_exists?(table, c) }
    assert_empty missing, "#{decision}: `#{table}` is missing #{missing.join(', ')}"
  end

  # --- D1 — ledger / valuation multiplicity (rank 1) ---

  test "D1: ledgers table exists with posts_to_gl and extension-ledger columns" do
    assert_columns("ledgers",
      %w[tenant_id code kind underlying_ledger_id posts_to_gl valid_from valid_to], "D1")
  end

  test "D1: entry_lines carries ledger_id" do
    assert_columns("entry_lines", %w[ledger_id], "D1")
  end

  # --- D3 — the organisational spine (rank 3). Absent from M0-M6 entirely. ---

  test "D3: entities table exists with its own currency and FY variant" do
    assert_columns("entities",
      %w[tenant_id code legal_name functional_currency fiscal_year_variant jurisdiction_profile], "D3")
  end

  test "D3: offices carries entity_id and no longer carries has_own_gstin" do
    assert_columns("offices", %w[entity_id], "D3")
    assert_not conn.column_exists?("offices", "has_own_gstin"),
      "D3: `offices.has_own_gstin` is superseded by tax_registrations (owner answer Q2)"
  end

  test "D3: tax_registrations is an effective-dated master, not a column on offices" do
    assert_columns("tax_registrations",
      %w[tenant_id entity_id kind identifier jurisdiction state_code valid_from valid_to], "D3")
  end

  test "D3: entry_lines carries entity_id, office_id and tax_registration_id" do
    assert_columns("entry_lines", %w[entity_id office_id tax_registration_id], "D3")
  end

  test "D3: intercompany postings are matched by construction, not by a matching engine" do
    assert_columns("entry_lines", %w[partner_entity_id intercompany_transaction_id], "D3")
  end

  # --- D2 — the dimension set (rank 2). HYBRID per owner answer Q3. ---

  test "D2: entry_lines has committed typed dimension columns, not only a bag" do
    assert_columns("entry_lines",
      %w[cost_object_type cost_object_id profit_center_id segment_id functional_area_id
         line_class posting_layer], "D2")
  end

  test "D2: entry_lines has an extra jsonb bag for uncommitted dimensions" do
    assert_columns("entry_lines", %w[extra], "D2")
  end

  test "D2: the dimensions registry governs derivation and requiredness" do
    assert_columns("dimensions", %w[tenant_id code label value_type required_rule], "D2")
  end

  # --- D4 — currency (rank 4). CHILD TABLE per owner answer Q4. ---

  test "D4: journal_entry_line_amounts is a child table, not N columns on the line" do
    assert_columns("journal_entry_line_amounts",
      %w[entry_line_id slot_role currency minor_unit_exponent amount_minor
         rate rate_date rate_source rate_basis], "D4")
  end

  test "D4: amounts are signed minor units, not a debit/credit pair" do
    assert conn.table_exists?("journal_entry_line_amounts"),
      "D4: table `journal_entry_line_amounts` does not exist yet"
    %w[debit credit].each do |c|
      assert_not conn.column_exists?("journal_entry_line_amounts", c),
        "D4: `#{c}` must not exist — amounts are signed minor units; debit/credit lives only in the .khata export projection"
    end
  end

  # --- D5 — open items and clearing (rank 5). Absent from M0-M6 entirely. ---

  test "D5: entry_lines carries open-item state and its clearing key" do
    assert_columns("entry_lines",
      %w[open_item item_class assignment baseline_date cleared_by_entry_id cleared_on], "D5")
  end

  test "D5: payment-term outcomes are frozen on the open item at posting" do
    assert_columns("entry_lines", %w[due_date discount_pct discount_date], "D5")
  end

  # --- D6 — time and period (rank 6). Absent from M0-M6 entirely. ---

  test "D6: entries carry four dates, not two" do
    assert_columns("entries", %w[document_date posting_date entered_at], "D6")
  end

  test "D6: period identity is STORED, not derived from posting_date" do
    assert_columns("entries", %w[fiscal_year period_no], "D6")
  end

  test "D6: period control is a table, not a boolean" do
    skip "B3.4 — period_controls (D6 period model + control) not built yet"
    assert_columns("period_controls",
      %w[entity_id ledger_id account_class fiscal_year period_no state], "D6")
  end

  # --- D7 — reversal semantics (rank 7) ---

  test "D7: negative posting is distinguishable from counter-posting" do
    assert_columns("entry_lines", %w[is_negative_posting], "D7")
  end

  # --- D8 — document identity and numbering (rank 8) ---

  test "D8: number ranges are a table with a statutory series key, not a Postgres sequence" do
    assert_columns("number_ranges",
      %w[tenant_id entity_id office_id doc_type fiscal_year next_value], "D8")
  end

  test "D8: documents carry an external reference for duplicate-invoice detection" do
    assert_columns("documents", %w[external_reference], "D8")
  end

  # --- D11 — fat events and provenance (rank 10). Owner answer Q6. ---

  test "D11: ledger_events carries a payload schema_version distinct from hash_version" do
    assert_columns("ledger_events", %w[schema_version], "D11")
  end

  # --- D12 — the parties spine (rank 11). Owner answer Q5. ---

  test "D12: parties exist with a stable human-meaningful party_number" do
    assert_columns("parties", %w[tenant_id party_number], "D12")
  end

  test "D12: party roles are many-per-party, not baked into the table name" do
    assert_table("party_roles", "D12")
  end

  test "D12: entry_lines references a party and its role, not vendor_id/customer_id" do
    assert_columns("entry_lines", %w[party_id party_role], "D12")
  end

  # --- D13 — recorded authority (rank 12). The payload half is Batch 3. ---

  test "D13: RBAC is a matrix, not a role enum" do
    skip "M2 — role_templates/role_permissions/user_office_roles are M2, not Batch 3 (only the authority COLUMNS on entries are Batch 3)"
    assert_columns("role_templates", %w[tenant_id code], "D13")
    assert_table("role_permissions", "D13")
    assert_table("user_office_roles", "D13")
  end

  test "D13: entries record the authority they were posted under, not just the actor" do
    assert_columns("entries", %w[role_template_id posting_limit_id], "D13")
  end

  # --- D2 — the extras bag must never reach a statutory aggregation ---

  test "D2: extra jsonb is excluded from statutory aggregation" do
    assert conn.table_exists?("dimensions"), "D2: table `dimensions` does not exist yet"
    assert conn.column_exists?("dimensions", "committed"),
      "D2: `dimensions.committed` marks which dimensions are real columns; uncommitted ones live in `extra` and must never be aggregated"
  end

  # --- D1 — the balance invariant is per ledger, never global ---

  test "D1: balance is asserted per (entry, ledger), not globally" do
    skip "B3.2 — Posting::PostEntry (the per-(entry, ledger) balance assertion) not built yet"
    assert conn.table_exists?("entries"), "D1: table `entries` does not exist yet"
    assert Posting.const_defined?(:PostEntry),
      "D1: Posting::PostEntry must assert Dr=Cr per (entry, ledger) — a global check is not a weaker version of this, it is a wrong one"
  rescue NameError
    flunk "D1: Posting::PostEntry does not exist yet (Batch 3)"
  end
end
