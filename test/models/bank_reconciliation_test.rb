# frozen_string_literal: true

require "test_helper"

class BankReconciliationTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "bank-reconciliation@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Bank Reconciliation"
    )
  end

  test "statement import is idempotent and exact reconciliation survives a projection rebuild" do
    deposit = post_journal(Date.new(2026, 8, 1), 10_000, "Founder deposit")
    payment = post_journal(Date.new(2026, 8, 2), -2_500, "Bank charge")
    statement = import_statement(
      csv: <<~CSV,
        booking_date,value_date,amount,reference,description,counterparty
        2026-08-01,2026-08-01,100.00,DEP-1,Founder deposit,Founder
        2026-08-02,2026-08-02,-25.00,FEE-1,Bank charge,Bank
      CSV
      opening: "1000.00", closing: "1075.00"
    )

    assert_equal statement.id, import_statement(
      csv: <<~CSV,
        booking_date,value_date,amount,reference,description,counterparty
        2026-08-01,2026-08-01,100.00,DEP-1,Founder deposit,Founder
        2026-08-02,2026-08-02,-25.00,FEE-1,Bank charge,Bank
      CSV
      opening: "1000.00", closing: "1075.00"
    ).id
    assert_equal 2, statement.row_count
    imported_event = DomainEvent.find(statement.created_domain_event_id)
    assert_equal "bank_statement.imported", imported_event.action
    assert EventSigning.verify(imported_event)

    assert_equal 2, Banking::Reconcile.auto_match!(statement: statement, actor: @org.user)
    identities = statement.bank_statement_lines.in_statement_order.pluck(
      :matched_ledger_event_id, :matched_entry_line_no
    )
    assert_equal [ deposit.ledger_event_id, payment.ledger_event_id ].sort, identities.pluck(0).sort

    Banking::Reconcile.finalize!(statement: statement, actor: @org.user)
    assert_equal "reconciled", statement.reload.status
    assert_equal 2, DomainEvent.where(tenant_id: @org.tenant.id)
      .where(action: %w[bank_statement.auto_matched bank_statement.reconciled]).count

    Posting.rebuild!(@org.tenant.id)
    assert_equal identities, statement.bank_statement_lines.in_statement_order.pluck(
      :matched_ledger_event_id, :matched_entry_line_no
    )
    assert statement.bank_statement_lines.all? { |line| line.matched_entry_line.present? }
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]
  end

  test "ambiguous candidates stay unmatched and a ledger identity cannot be used twice" do
    first = post_journal(Date.new(2026, 8, 1), 10_000, "First deposit")
    post_journal(Date.new(2026, 8, 1), 10_000, "Second deposit")
    statement = import_statement(
      csv: statement_csv("100.00", reference: "AMB-1"), opening: "0", closing: "100"
    )
    line = statement.bank_statement_lines.sole

    assert_equal 0, Banking::Reconcile.auto_match!(statement: statement, actor: @org.user)
    assert_equal "unmatched", line.reload.status
    assert_equal 2, Banking::Reconcile.candidates_for(line).count

    selected = Entry.find_by!(ledger_event_id: first.ledger_event_id).entry_lines.find_by!(account_code: "1010")
    Banking::Reconcile.manual_match!(line: line, entry_line: selected, actor: @org.user)
    assert_equal "manual", line.reload.match_method

    other_statement = import_statement(
      csv: statement_csv("100.00", reference: "AMB-2"), opening: "0", closing: "100",
      file_name: "other.csv"
    )
    error = assert_raises(Banking::InvalidStatement) do
      Banking::Reconcile.manual_match!(
        line: other_statement.bank_statement_lines.sole, entry_line: selected, actor: @org.user
      )
    end
    assert_match(/does not match/, error.message)
  end

  test "closing requires every line resolved and balances to bridge" do
    statement = import_statement(
      csv: statement_csv("10.00", reference: "IGNORE-1"), opening: "50", closing: "60"
    )
    line = statement.bank_statement_lines.sole

    assert_match(/still unmatched/, assert_raises(Banking::InvalidStatement) {
      Banking::Reconcile.finalize!(statement: statement, actor: @org.user)
    }.message)
    assert_raises(ActiveRecord::RecordInvalid) do
      Banking::Reconcile.ignore!(line: line, actor: @org.user, reason: "")
    end

    Banking::Reconcile.ignore!(line: line.reload, actor: @org.user, reason: "Non-ledger bank memo")
    Banking::Reconcile.finalize!(statement: statement.reload, actor: @org.user)
    assert_equal "reconciled", statement.reload.status

    unbalanced = import_statement(
      csv: statement_csv("10.00", reference: "BAD-BALANCE"), opening: "50", closing: "70",
      file_name: "unbalanced.csv"
    )
    Banking::Reconcile.ignore!(
      line: unbalanced.bank_statement_lines.sole, actor: @org.user, reason: "Investigated memo"
    )
    assert_match(/does not reconcile/, assert_raises(Banking::InvalidStatement) {
      Banking::Reconcile.finalize!(statement: unbalanced, actor: @org.user)
    }.message)
  end

  test "CSV contract rejects unknown columns and changed metadata on a duplicate source" do
    malformed = <<~CSV
      booking_date,value_date,amount,reference,description,counterparty,surprise
      2026-08-01,2026-08-01,100.00,DEP-1,Deposit,Founder,nope
    CSV
    assert_match(/unknown columns: surprise/, assert_raises(Banking::InvalidStatement) {
      import_statement(csv: malformed, opening: "0", closing: "100")
    }.message)

    csv = statement_csv("100.00", reference: "DUP-1")
    import_statement(csv: csv, opening: "0", closing: "100")
    assert_match(/different statement metadata/, assert_raises(Banking::InvalidStatement) {
      import_statement(csv: csv, opening: "10", closing: "110")
    }.message)
  end

  private

  def post_journal(date, bank_amount, narration)
    offset_code = bank_amount.positive? ? "3000" : "5000"
    document = Documents::BuildDraft.call(
      tenant: @org.tenant, doc_type: "JV", document_date: date, posting_date: date,
      narration: narration,
      lines: [
        { account_code: "1010", amount_minor: bank_amount, currency: "INR" },
        { account_code: offset_code, amount_minor: -bank_amount, currency: "INR" }
      ]
    )
    Documents::Post.call(
      document, actor: "u:#{@org.user.id}", authorize: { user: @org.user }
    )
  end

  def import_statement(csv:, opening:, closing:, file_name: "statement.csv")
    Banking::ImportStatement.call(
      tenant: @org.tenant, actor: @org.user, bank_account_code: "1010", currency: "INR",
      opening_balance: opening, closing_balance: closing, file_name: file_name, csv_text: csv
    )
  end

  def statement_csv(amount, reference:)
    <<~CSV
      booking_date,value_date,amount,reference,description,counterparty
      2026-08-01,2026-08-01,#{amount},#{reference},Bank transaction,Bank
    CSV
  end
end
