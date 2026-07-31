# frozen_string_literal: true

require "test_helper"

class ReportsTest < ActiveSupport::TestCase
  TENANT = 97_002

  test "trial balance supports numeric and alphanumeric account codes" do
    ledger = Ledger.create!(tenant_id: TENANT, code: "PRIMARY", name: "Primary")
    Account.create!(tenant_id: TENANT, code: "10", name: "Numeric", account_type: "asset")
    Account.create!(tenant_id: TENANT, code: "AR-20", name: "Receivable", account_type: "asset")
    entry = Entry.create!(tenant_id: TENANT, document_date: Date.current, posting_date: Date.current,
      entered_at: Time.current, fiscal_year: 2026, period_no: 1)
    add_line(entry, 1, "10", 100, ledger_id: ledger.id)
    add_line(entry, 2, "AR-20", -100, ledger_id: ledger.id)

    rows = Reports.trial_balance(TENANT)

    assert_equal [ 10, "AR-20" ], rows.pluck("account_id")
  end

  test "trial balance excludes statistical lines and ledgers that do not post to GL" do
    Account.create!(tenant_id: TENANT, code: "1000", name: "Cash", account_type: "asset")
    Account.create!(tenant_id: TENANT, code: "4000", name: "Sales", account_type: "income")
    primary = Ledger.create!(tenant_id: TENANT, code: "PRIMARY", name: "Primary")
    statistical = Ledger.create!(
      tenant_id: TENANT, code: "STAT", name: "Statistical", posts_to_gl: false
    )
    entry = Entry.create!(tenant_id: TENANT, document_date: Date.current, posting_date: Date.current,
      entered_at: Time.current, fiscal_year: 2026, period_no: 1)
    add_line(entry, 1, "1000", 100, ledger_id: primary.id)
    add_line(entry, 2, "4000", -100, ledger_id: primary.id)
    add_line(entry, 1, "1000", 900, ledger_id: statistical.id)
    add_line(entry, 2, "4000", -900, ledger_id: statistical.id)
    add_line(entry, 3, "1000", 700, ledger_id: primary.id, line_class: "statistical")
    add_line(entry, 4, "4000", -700, ledger_id: primary.id, line_class: "statistical")

    rows = Reports.trial_balance(TENANT).index_by { |row| row.fetch("account_id") }

    assert_equal 100, rows.fetch(1000).fetch("debit")
    assert_equal 100, rows.fetch(4000).fetch("credit")
  end

  private

  def add_line(entry, line_no, account_code, amount_minor, ledger_id:, line_class: "real")
    line = EntryLine.create!(tenant_id: TENANT, entry: entry, line_no: line_no,
      account_code: account_code, ledger_id: ledger_id, entity_id: 1, office_id: 1,
      line_class: line_class)
    line.amounts.create!(tenant_id: TENANT, slot_role: "transaction", currency: "INR",
      minor_unit_exponent: 2, amount_minor: amount_minor)
  end
end
