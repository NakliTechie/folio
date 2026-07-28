# frozen_string_literal: true

require "test_helper"

# B3.3 — open-item clearing (D5). The load-bearing distinction: partial clearing PRESERVES
# ageing, residual clearing RESETS it. And the whole thing is event-sourced, so a rebuild
# from the log reconstructs the cleared state.
class Posting::ClearingTest < ActiveSupport::TestCase
  TENANT = 77
  APR2 = Date.new(2025, 4, 2)
  JUN1 = Date.new(2025, 6, 1)
  JUL1 = Date.new(2025, 7, 1)

  def post_invoice(assignment:)
    Posting::PostEntry.post!(
      tenant_id: TENANT, entity_id: 1, office_id: 1, actor: "u:1", origin: "folio",
      document_date: APR2, posting_date: APR2, entered_at: Time.utc(2025, 4, 2, 9), fiscal_year: 2025, period_no: 1,
      lines: [
        { line_no: 1, account_code: "100100", ledger_id: 1, entity_id: 1, office_id: 1,
          party_id: 55, party_role: "customer", open_item: true, item_class: "normal",
          assignment: assignment, baseline_date: APR2, due_date: Date.new(2025, 5, 2),
          amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2, amount_minor: 100_000 } ] },
        { line_no: 2, account_code: "400000", ledger_id: 1, entity_id: 1, office_id: 1,
          amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2, amount_minor: -100_000 } ] }
      ]
    )
  end

  def post_payment
    Posting::PostEntry.post!(
      tenant_id: TENANT, entity_id: 1, office_id: 1, actor: "u:1", origin: "folio",
      document_date: JUN1, posting_date: JUN1, entered_at: Time.utc(2025, 6, 1, 9), fiscal_year: 2025, period_no: 3,
      lines: [
        { line_no: 1, account_code: "100200", ledger_id: 1, entity_id: 1, office_id: 1,
          amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2, amount_minor: 120_000 } ] },
        { line_no: 2, account_code: "100100", ledger_id: 1, entity_id: 1, office_id: 1,
          amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2, amount_minor: -120_000 } ] }
      ]
    )
  end

  def item_for(assignment)
    EntryLine.where(tenant_id: TENANT, assignment: assignment, residual_of_line_id: nil).order(:id).first
  end

  test "partial preserves ageing; residual resets it" do
    post_invoice(assignment: "INV-1")
    post_invoice(assignment: "INV-2")
    payment = post_payment

    Posting::Clearing.clear!(item: item_for("INV-1"), amount_minor: 60_000, cleared_on: JUN1,
                             mode: :partial, clearing_entry: payment)
    Posting::Clearing.clear!(item: item_for("INV-2"), amount_minor: 60_000, cleared_on: JUN1,
                             mode: :residual, clearing_entry: payment)

    # INV-1 (partial): original still open, outstanding halved, baseline UNCHANGED.
    inv1 = item_for("INV-1")
    assert_nil inv1.cleared_on, "partial keeps the original open"
    assert_equal 60_000, inv1.cleared_amount_minor
    assert_equal 40_000, Posting::Clearing.open_amount(inv1)
    assert_equal APR2, inv1.baseline_date, "partial preserves the original baseline"

    # INV-2 (residual): original CLEARED, a new open item for the balance with a fresh baseline.
    inv2 = item_for("INV-2")
    assert_equal JUN1, inv2.cleared_on, "residual clears the original"
    residual = EntryLine.find_by!(residual_of_line_id: inv2.id)
    assert residual.open_item
    assert_equal JUN1, residual.baseline_date, "residual RESETS the baseline"
    assert_equal 40_000, Posting::Clearing.open_amount(residual)

    # Ageing as of Jul 1: the partial's still-open item is older than the residual's new item.
    partial_age = Posting::Clearing.age_days(inv1, as_of: JUL1)      # from Apr 2 → ~90
    residual_age = Posting::Clearing.age_days(residual, as_of: JUL1) # from Jun 1 → 30
    assert_equal 90, partial_age
    assert_equal 30, residual_age
    assert_operator partial_age, :>, residual_age,
      "partial preserves ageing (older), residual resets it (younger) — the whole point"
  end

  test "clearing appends events (never an UPDATE to the log) and the chain still verifies" do
    post_invoice(assignment: "INV-9")
    before = LedgerEvent.for_tenant(TENANT).count
    Posting::Clearing.clear!(item: item_for("INV-9"), amount_minor: 100_000, cleared_on: JUN1, mode: :full)
    assert_equal before + 1, LedgerEvent.for_tenant(TENANT).count, "clearing is a new event"
    assert_equal "items.cleared", LedgerEvent.for_tenant(TENANT).in_order.last.action
    assert Posting::Clearing.open_amount(item_for("INV-9")).zero?
    assert LedgerEvent.verify_chain(TENANT)[:ok]
  end

  test "the cleared state rebuilds from the event log" do
    post_invoice(assignment: "INV-1")
    post_invoice(assignment: "INV-2")
    payment = post_payment
    Posting::Clearing.clear!(item: item_for("INV-1"), amount_minor: 60_000, cleared_on: JUN1,
                             mode: :partial, clearing_entry: payment)
    Posting::Clearing.clear!(item: item_for("INV-2"), amount_minor: 60_000, cleared_on: JUN1,
                             mode: :residual, clearing_entry: payment)

    Posting.rebuild!(TENANT)

    # Same cleared state after a full wipe-and-replay from the log.
    assert_equal 40_000, Posting::Clearing.open_amount(item_for("INV-1"))
    assert_nil item_for("INV-1").cleared_on
    inv2 = item_for("INV-2")
    assert_equal JUN1, inv2.cleared_on
    residual = EntryLine.find_by!(residual_of_line_id: inv2.id)
    assert_equal JUN1, residual.baseline_date
    assert_equal 40_000, Posting::Clearing.open_amount(residual)
  end

  test "over-clearing is rejected" do
    post_invoice(assignment: "INV-X")
    assert_raises(ArgumentError) do
      Posting::Clearing.clear!(item: item_for("INV-X"), amount_minor: 100_001, cleared_on: JUN1, mode: :partial)
    end
  end
end
