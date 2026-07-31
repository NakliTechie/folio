# frozen_string_literal: true

require "test_helper"

class Posting::RebuildTest < ActiveSupport::TestCase
  TENANT = 97_001

  test "a replay failure preserves the prior readable projection" do
    entry = Posting::PostEntry.post!(draft)
    original_entry_id = entry.id
    original_line_ids = entry.entry_lines.order(:line_no).pluck(:id)

    LedgerEvent.append!(
      tenant_id: TENANT, actor: "test", action: "entry.posted", origin: "test",
      ts: "2025-06-02", payload_str: '{"entry":{},"lines":[]}'
    )

    assert_raises(ActiveRecord::RecordInvalid) { Posting.rebuild!(TENANT) }
    assert_equal [ original_entry_id ], Entry.where(tenant_id: TENANT).pluck(:id)
    assert_equal original_line_ids, EntryLine.where(tenant_id: TENANT).order(:line_no).pluck(:id)
  end

  test "the database prevents duplicate event and document projections" do
    indexes = ActiveRecord::Base.connection.indexes(:entries).index_by(&:name)
    event_index = indexes.fetch("index_entries_on_tenant_event_unique")
    document_index = indexes.fetch("index_entries_on_tenant_document_unique")

    assert event_index.unique
    assert_equal %w[tenant_id ledger_event_id], event_index.columns
    assert_equal "(ledger_event_id IS NOT NULL)", event_index.where
    assert document_index.unique
    assert_equal %w[tenant_id document_id], document_index.columns
    assert_equal "(document_id IS NOT NULL)", document_index.where
  end

  private

  def draft
    {
      tenant_id: TENANT, actor: "test", origin: "test",
      document_date: Date.new(2025, 6, 1), posting_date: Date.new(2025, 6, 1),
      entered_at: Time.utc(2025, 6, 1, 9), fiscal_year: 2025, period_no: 3,
      lines: [
        { line_no: 1, account_code: "1000", ledger_id: 1, entity_id: 1, office_id: 1,
          amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2,
                       amount_minor: 100 } ] },
        { line_no: 2, account_code: "4000", ledger_id: 1, entity_id: 1, office_id: 1,
          amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2,
                       amount_minor: -100 } ] }
      ]
    }
  end
end
