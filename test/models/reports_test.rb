# frozen_string_literal: true

require "test_helper"

class ReportsTest < ActiveSupport::TestCase
  TENANT = 97_002

  test "trial balance supports numeric and alphanumeric account codes" do
    Account.create!(tenant_id: TENANT, code: "10", name: "Numeric", account_type: "asset")
    Account.create!(tenant_id: TENANT, code: "AR-20", name: "Receivable", account_type: "asset")
    entry = Entry.create!(tenant_id: TENANT, document_date: Date.current, posting_date: Date.current,
      entered_at: Time.current, fiscal_year: 2026, period_no: 1)
    add_line(entry, 1, "10", 100)
    add_line(entry, 2, "AR-20", -100)

    rows = Reports.trial_balance(TENANT)

    assert_equal [ 10, "AR-20" ], rows.pluck("account_id")
  end

  private

  def add_line(entry, line_no, account_code, amount_minor)
    line = EntryLine.create!(tenant_id: TENANT, entry: entry, line_no: line_no,
      account_code: account_code, ledger_id: 1, entity_id: 1, office_id: 1)
    line.amounts.create!(tenant_id: TENANT, slot_role: "transaction", currency: "INR",
      minor_unit_exponent: 2, amount_minor: amount_minor)
  end
end
