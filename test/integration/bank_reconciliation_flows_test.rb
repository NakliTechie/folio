# frozen_string_literal: true

require "test_helper"

class BankReconciliationFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "bank-browser@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Bank Browser"
    )
    sign_in_as(@org.user)
    post_deposit
  end

  test "owner imports, matches, and closes a statement in the browser" do
    get bank_reconciliations_path
    assert_response :success
    assert_select "h1", "Bank reconciliation"

    assert_difference "BankStatementImport.count", 1 do
      post import_statement_bank_reconciliations_path, params: {
        bank_account_code: "1010", currency: "INR",
        opening_balance: "0", closing_balance: "100",
        statement_file: fixture_file_upload("bank_statement.csv", "text/csv")
      }
    end
    statement = BankStatementImport.order(:id).last
    assert_redirected_to bank_reconciliation_path(statement, tenant_id: @org.tenant.id)

    post auto_match_bank_reconciliation_path(statement), params: { tenant_id: @org.tenant.id }
    assert_redirected_to bank_reconciliation_path(statement, tenant_id: @org.tenant.id)
    assert_equal "matched", statement.bank_statement_lines.sole.reload.status

    post finalize_bank_reconciliation_path(statement), params: { tenant_id: @org.tenant.id }
    assert_redirected_to bank_reconciliation_path(statement, tenant_id: @org.tenant.id)
    follow_redirect!
    assert_select ".status-badge--success", text: "Reconciled"
    assert_select "form[action='#{auto_match_bank_reconciliation_path(statement)}']", count: 0
  end

  test "viewer sees reconciliation evidence but no mutation controls" do
    statement = Banking::ImportStatement.call(
      tenant: @org.tenant, actor: @org.user, bank_account_code: "1010", currency: "INR",
      opening_balance: "0", closing_balance: "100", file_name: "bank_statement.csv",
      csv_text: Rails.root.join("test/fixtures/files/bank_statement.csv").read
    )
    viewer = invite_user("bank-viewer@folio.invalid", "viewer")
    sign_out
    sign_in_as(viewer)

    get bank_reconciliations_path
    assert_response :success
    assert_select "form[action='#{import_statement_bank_reconciliations_path}']", count: 0
    get bank_reconciliation_path(statement)
    assert_response :success
    assert_select "form[action='#{auto_match_bank_reconciliation_path(statement)}']", count: 0

    assert_no_changes -> { statement.bank_statement_lines.sole.reload.status } do
      post auto_match_bank_reconciliation_path(statement)
    end
    assert_redirected_to root_path(tenant_id: @org.tenant.id)
  end

  private

  def post_deposit
    document = Documents::BuildDraft.call(
      tenant: @org.tenant, doc_type: "JV",
      document_date: Date.new(2026, 8, 1), posting_date: Date.new(2026, 8, 1),
      narration: "Founder deposit",
      lines: [
        { account_code: "1010", amount_minor: 10_000, currency: "INR" },
        { account_code: "3000", amount_minor: -10_000, currency: "INR" }
      ]
    )
    Documents::Post.call(
      document, actor: "u:#{@org.user.id}", authorize: { user: @org.user }
    )
  end

  def invite_user(email, role_code)
    invitation = Onboarding::Invite.create!(
      tenant: @org.tenant, email: email, role_code: role_code, invited_by: @org.user
    )
    Onboarding::Invite.accept!(
      token: invitation.generate_token_for(:invite), password: "correct-horse-battery"
    )
  end
end
