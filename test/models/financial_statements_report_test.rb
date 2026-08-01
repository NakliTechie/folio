# frozen_string_literal: true

require "test_helper"

class FinancialStatementsReportTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "statements@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Statement Books"
    )
  end

  test "profit and loss uses the dated presentation mapping and requested period" do
    post_journal(date: Date.new(2026, 4, 5), debit: "1000", credit: "4000", amount: 100_000)
    post_journal(date: Date.new(2026, 5, 5), debit: "5100", credit: "1000", amount: 40_000)
    post_journal(date: Date.new(2027, 4, 5), debit: "5100", credit: "1000", amount: 10_000)

    report = Reports.profit_and_loss(@org.tenant.id,
      from_date: Date.new(2026, 4, 1), to_date: Date.new(2027, 3, 31))

    assert_equal 100_000, report[:income_minor]
    assert_equal 40_000, report[:expenses_minor]
    assert_equal 60_000, report[:net_income_minor]
    assert_equal 1, report.dig(:version, :version)
    assert_empty report[:unmapped_accounts]
  end

  test "balance sheet includes accumulated earnings and proves the equation" do
    post_journal(date: Date.new(2026, 4, 5), debit: "1000", credit: "4000", amount: 100_000)
    post_journal(date: Date.new(2026, 5, 5), debit: "5100", credit: "1000", amount: 40_000)

    report = Reports.balance_sheet(@org.tenant.id, as_of: Date.new(2026, 5, 31))

    assert_equal 60_000, report[:assets_minor]
    assert_equal 60_000, report[:equity_liabilities_minor]
    assert_equal 0, report[:difference_minor]
    earnings = report[:rows].find { |row| row[:code] == "accumulated_earnings" }
    assert_equal 60_000, earnings[:amount_minor]
  end

  test "statutory statements exclude statistical lines and non-GL ledgers" do
    primary = Ledger.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    statistical = Ledger.create!(
      tenant_id: @org.tenant.id, code: "STAT", name: "Statistical", posts_to_gl: false
    )
    post_ledger_slice(ledger: statistical, line_class: "real", amount: 90_000)
    post_ledger_slice(ledger: primary, line_class: "statistical", amount: 70_000)

    profit = Reports.profit_and_loss(
      @org.tenant.id, from_date: Date.new(2026, 4, 1), to_date: Date.new(2027, 3, 31)
    )
    balance = Reports.balance_sheet(@org.tenant.id, as_of: Date.new(2027, 3, 31))

    assert_equal 0, profit[:net_income_minor]
    assert_equal 0, balance[:assets_minor]
    assert_equal 0, balance[:equity_liabilities_minor]
  end

  test "a posted but unmapped account is called out instead of silently omitted" do
    sales = Account.find_by!(tenant_id: @org.tenant.id, code: "4000")
    FinancialStatementAssignment.where(account_id: sales.id).delete_all
    post_journal(date: Date.new(2026, 4, 5), debit: "1000", credit: "4000", amount: 100_000)

    report = Reports.profit_and_loss(@org.tenant.id,
      from_date: Date.new(2026, 4, 1), to_date: Date.new(2027, 3, 31))

    assert_equal [ { code: "4000", name: "Sales" } ], report[:unmapped_accounts]
    assert_equal 0, report[:income_minor]
  end

  test "opening-balance documents post in special period zero" do
    entry = post_journal(date: Date.new(2026, 4, 1), debit: "1000", credit: "3000",
      amount: 250_000, doc_type: "OB")

    assert_equal 0, entry.period_no
    assert_equal "OB/1", entry.document.document_number
    report = Reports.balance_sheet(@org.tenant.id, as_of: Date.new(2026, 4, 1))
    assert_equal 250_000, report[:assets_minor]
    assert_equal 250_000, report[:equity_liabilities_minor]
  end

  test "period-zero income and expense rows never contaminate profit and loss" do
    ledger = Ledger.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    Posting::PostEntry.post!(
      tenant_id: @org.tenant.id, actor: "legacy-import", origin: "test",
      document_date: Date.new(2026, 4, 1), posting_date: Date.new(2026, 4, 1),
      entered_at: Time.utc(2026, 4, 1), fiscal_year: 2026, period_no: 0,
      lines: [
        { line_no: 1, account_code: "1000", ledger_id: ledger.id,
          entity_id: entity.id, office_id: office.id,
          amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2,
                       amount_minor: 50_000 } ] },
        { line_no: 2, account_code: "4000", ledger_id: ledger.id,
          entity_id: entity.id, office_id: office.id,
          amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2,
                       amount_minor: -50_000 } ] }
      ]
    )

    report = Reports.profit_and_loss(
      @org.tenant.id, from_date: Date.new(2026, 4, 1), to_date: Date.new(2027, 3, 31)
    )
    assert_equal 0, report[:income_minor]
    assert_equal 0, report[:net_income_minor]
  end

  test "opening-balance posting rejects profit-and-loss accounts" do
    document = assert_raises(Documents::InvalidDocument) do
      post_journal(date: Date.new(2026, 4, 1), debit: "1000", credit: "4000",
        amount: 25_000, doc_type: "OB")
    end
    assert_match(/only asset, liability, and equity/, document.message)
  end

  test "published layouts are immutable and future changes use a cloned version" do
    original = FinancialStatementVersion.resolve!(tenant_id: @org.tenant.id, on: Date.new(2026, 4, 1))
    refute original.update(name: "Rewritten history")
    assert_match(/immutable/, original.errors.full_messages.to_sentence)
    section = original.financial_statement_sections.find_by!(code: "operating_revenue")
    refute section.update(label: "Rewritten revenue")
    assert_match(/immutable/, section.errors.full_messages.to_sentence)

    draft = FinancialStatements::Versions.clone!(
      source: original, effective_from: Date.new(2027, 4, 1), name: "FY 2027 presentation"
    )
    draft.financial_statement_sections.find_by!(code: "operating_revenue").update!(label: "Revenue from operations")
    FinancialStatements::Versions.publish!(draft)

    assert_equal original.id,
      FinancialStatementVersion.resolve!(tenant_id: @org.tenant.id, on: Date.new(2027, 3, 31)).id
    assert_equal draft.id,
      FinancialStatementVersion.resolve!(tenant_id: @org.tenant.id, on: Date.new(2027, 4, 1)).id
    assert_equal Date.new(2027, 3, 31), original.reload.effective_to
    assert_equal "retired", original.status
    assert_equal "active", draft.reload.status
  end

  test "activation rejects cyclic trees and overlapping effective versions" do
    original = FinancialStatementVersion.resolve!(tenant_id: @org.tenant.id, on: Date.current)
    cyclic = FinancialStatements::Versions.clone!(source: original, effective_from: Date.current + 1.year)
    assets = cyclic.financial_statement_sections.find_by!(code: "assets")
    current_assets = cyclic.financial_statement_sections.find_by!(code: "current_assets")
    assets.update!(parent: current_assets)

    error = assert_raises(FinancialStatements::InvalidLayout) do
      FinancialStatements::Versions.publish!(cyclic)
    end
    assert_match(/cycle/, error.message)

    assets.update!(parent: nil)
    FinancialStatements::Versions.publish!(cyclic)
    overlap = FinancialStatements::Versions.clone!(source: cyclic, effective_from: cyclic.effective_from)
    error = assert_raises(FinancialStatements::InvalidLayout) do
      FinancialStatements::Versions.publish!(overlap)
    end
    assert_match(/must start after/, error.message)
  end

  test "a posted account mapping cannot be changed inside its published version" do
    post_journal(date: Date.new(2026, 4, 5), debit: "1000", credit: "4000", amount: 100_000)
    sales = Account.find_by!(tenant_id: @org.tenant.id, code: "4000")
    assignment = sales.financial_statement_assignments.first
    other_income = assignment.financial_statement_version.financial_statement_sections.find_by!(code: "other_income")

    refute assignment.update(financial_statement_section: other_income)
    assert_match(/immutable/, assignment.errors.full_messages.to_sentence)
  end

  test "the default layout remains idempotent after accounts have postings" do
    post_journal(date: Date.new(2026, 4, 5), debit: "1000", credit: "4000", amount: 100_000)
    assignments = FinancialStatementAssignment.where(tenant_id: @org.tenant.id)
    original_ids = assignments.order(:account_id).pluck(:id)

    version = FinancialStatements::DefaultLayout.ensure!(@org.tenant)

    assert_equal "active", version.status
    assert_equal original_ids, assignments.reload.order(:account_id).pluck(:id)
  end

  test "a new account is mapped across historical and future statement versions" do
    original = FinancialStatementVersion.resolve!(tenant_id: @org.tenant.id, on: Date.current)
    future = FinancialStatements::Versions.clone!(
      source: original, effective_from: Date.current + 1.year, name: "Future presentation"
    )
    FinancialStatements::Versions.publish!(future)

    account = Accounts::Manage.create!(
      tenant: @org.tenant,
      attributes: { code: "4010", name: "Consulting income", account_type: "income" },
      actor: @org.user
    )

    mappings = account.financial_statement_assignments.includes(:financial_statement_section)
      .index_by(&:financial_statement_version_id)
    assert_equal [ original.id, future.id ].sort, mappings.keys.sort
    assert_equal "operating_revenue", mappings.fetch(original.id).financial_statement_section.code
    assert_equal "operating_revenue", mappings.fetch(future.id).financial_statement_section.code
  end

  private

  def post_ledger_slice(ledger:, line_class:, amount:)
    Posting::PostEntry.post!(
      tenant_id: @org.tenant.id, actor: "test", origin: "test",
      document_date: Date.new(2026, 4, 5), posting_date: Date.new(2026, 4, 5),
      entered_at: Time.utc(2026, 4, 5), fiscal_year: 2026, period_no: 1,
      lines: [
        { line_no: 1, account_code: "1000", ledger_id: ledger.id,
          entity_id: 1, office_id: 1, line_class: line_class,
          amounts: [ { slot_role: "transaction", currency: "INR",
                       minor_unit_exponent: 2, amount_minor: amount } ] },
        { line_no: 2, account_code: "4000", ledger_id: ledger.id,
          entity_id: 1, office_id: 1, line_class: line_class,
          amounts: [ { slot_role: "transaction", currency: "INR",
                       minor_unit_exponent: 2, amount_minor: -amount } ] }
      ]
    )
  end

  def post_journal(date:, debit:, credit:, amount:, doc_type: "JV")
    entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    type = DocumentType.find_by!(tenant_id: @org.tenant.id, code: doc_type)
    doc = Document.create!(tenant_id: @org.tenant.id, entity_id: entity.id, office_id: office.id,
      doc_type: doc_type, document_type: type,
      fiscal_year: Documents.fiscal_year(date, variant: entity.fiscal_year_variant),
      document_date: date, posting_date: date, state: "draft")
    doc.document_lines.create!(tenant_id: @org.tenant.id, line_no: 1,
      account_code: debit, amount_minor: amount)
    doc.document_lines.create!(tenant_id: @org.tenant.id, line_no: 2,
      account_code: credit, amount_minor: -amount)
    Documents::Post.call(doc, actor: "u:#{@org.user.id}")
  end
end
