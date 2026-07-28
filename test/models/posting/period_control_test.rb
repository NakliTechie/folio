# frozen_string_literal: true

require "test_helper"

# B3.4 — period control (D6), enforced in the engine on the single posting entry point.
class Posting::PeriodControlTest < ActiveSupport::TestCase
  TENANT = 88

  def draft(period_no: 3, account_class: nil, capabilities: nil)
    lines = [
      { line_no: 1, account_code: "100100", ledger_id: 1, entity_id: 1, office_id: 1,
        amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2, amount_minor: 100_000 } ] },
      { line_no: 2, account_code: "400000", ledger_id: 1, entity_id: 1, office_id: 1,
        amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2, amount_minor: -100_000 } ] }
    ]
    lines.each { |l| l[:account_class] = account_class } if account_class
    d = {
      tenant_id: TENANT, entity_id: 1, office_id: 1, actor: "u:1", origin: "folio",
      document_date: Date.new(2025, 6, 1), posting_date: Date.new(2025, 6, 1),
      entered_at: Time.utc(2025, 6, 2, 9), fiscal_year: 2025, period_no: period_no, lines: lines
    }
    d[:capabilities] = capabilities if capabilities
    d
  end

  def control!(period_no:, state:, account_class: "ALL", capability: nil, domain: "posting")
    PeriodControl.create!(tenant_id: TENANT, entity_id: 1, ledger_id: 1, account_class: account_class,
      fiscal_year: 2025, period_no: period_no, state: state, capability: capability, domain: domain)
  end

  test "with no control, a post succeeds (default open)" do
    assert Posting::PostEntry.post!(draft).persisted?
  end

  test "a post into a closed period is rejected and writes nothing" do
    control!(period_no: 3, state: "closed")
    before = LedgerEvent.for_tenant(TENANT).count
    assert_raises(Posting::PeriodClosedError) { Posting::PostEntry.post!(draft(period_no: 3)) }
    assert_equal before, LedgerEvent.for_tenant(TENANT).count, "a rejected post appends no event"
  end

  test "a special period is accepted unless it too is controlled" do
    assert Posting::PostEntry.post!(draft(period_no: 13)).persisted?, "period 13 is open by default"
    control!(period_no: 14, state: "closed")
    assert_raises(Posting::PeriodClosedError) { Posting::PostEntry.post!(draft(period_no: 14)) }
  end

  test "a restricted period needs the named capability" do
    control!(period_no: 3, state: "restricted", capability: "period.adjust")
    assert_raises(Posting::PeriodRestrictedError) { Posting::PostEntry.post!(draft(period_no: 3)) }
    assert Posting::PostEntry.post!(draft(period_no: 3, capabilities: [ "period.adjust" ])).persisted?
  end

  test "account_class scopes the lock — closing AP does not close GL" do
    control!(period_no: 3, state: "closed", account_class: "AP")
    assert Posting::PostEntry.post!(draft(period_no: 3)).persisted?, "GL lines post fine while AP is closed"
    assert_raises(Posting::PeriodClosedError) { Posting::PostEntry.post!(draft(period_no: 3, account_class: "AP")) }
  end

  test "the tax lock is a separate domain from the posting lock" do
    control!(period_no: 3, state: "closed", domain: "tax")
    assert Posting::PostEntry.post!(draft(period_no: 3)).persisted?, "a tax lock does not block posting"
  end

  test "a specific account_class wins over the ALL wildcard" do
    control!(period_no: 3, state: "closed", account_class: "ALL")
    control!(period_no: 3, state: "open", account_class: "AP")
    assert Posting::PostEntry.post!(draft(period_no: 3, account_class: "AP")).persisted?, "AP is explicitly open"
    assert_raises(Posting::PeriodClosedError) { Posting::PostEntry.post!(draft(period_no: 3)) }
  end

  test "replay does NOT re-check period control — a historical event reproduces after a close" do
    entry = Posting::PostEntry.post!(draft(period_no: 3))
    event = LedgerEvent.find(entry.ledger_event_id)
    control!(period_no: 3, state: "closed") # close the period AFTER the fact
    entry.destroy!
    assert Posting::PostEntry.replay!(event).persisted?,
      "replay must reproduce the projection regardless of the period's current state"
  end
end
