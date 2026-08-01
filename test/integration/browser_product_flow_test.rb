# frozen_string_literal: true

require "test_helper"

class BrowserProductFlowTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "browser-owner@x.com", password: "correct-horse-battery", org_name: "Browser Books"
    )
    sign_in_as(@org.user)
  end

  test "owner can move from overview through a posted voucher to the trial balance" do
    get root_path
    assert_response :success
    assert_select "h1", "Your books, at a glance"
    assert_select "a", "Choose your first business event"
    assert_select "a", "Chart of accounts"
    assert_select "details.mobile-user-menu button", "Sign out"

    assert_difference "Document.count", 1 do
      post journal_vouchers_path, params: {
        journal_voucher: {
          posting_date: "2026-07-30",
          event_kind: "owner_deposit",
          contributor: "Founder",
          amount: "1250.50",
          cash_account_code: "1000"
        }
      }
    end
    document = Document.order(:id).last
    assert_redirected_to journal_voucher_path(document, tenant_id: @org.tenant.id)

    follow_redirect!
    assert_select "h2", "Balanced and ready to post"
    assert_select "td", text: "INR 1,250.50", count: 4
    assert_select "a", "Edit draft"
    assert_select "button", "Discard draft"

    post post_journal_voucher_path(document, tenant_id: @org.tenant.id)
    assert_redirected_to reports_path(tenant_id: @org.tenant.id, posted_document_id: document.id)
    follow_redirect!
    assert_select "h1", "Trial balance"
    assert_select "[role=status]", text: /Cash increased by INR 1,250\.50.*Capital increased/m
    assert_select "tr.table-row--highlight", 2
    assert_select ".summary-strip small", text: "Credit balance"
    assert_equal "posted", document.reload.state
  end

  test "a journal draft can be edited without losing values and then discarded" do
    post journal_vouchers_path, params: {
      journal_voucher: {
        event_kind: "journal", posting_date: "2026-07-30", narration: "Draft purpose",
        amount: "10.25", debit_account_code: "1000", credit_account_code: "3000"
      }
    }
    document = Document.order(:id).last

    get edit_journal_voucher_path(document)
    assert_response :success
    assert_select "input[name='journal_voucher[amount]'][value='10.25']"
    assert_select "input[name='journal_voucher[narration]'][value='Draft purpose']"

    patch journal_voucher_path(document), params: {
      journal_voucher: {
        event_kind: "journal", posting_date: "2026-07-31", narration: "Updated purpose",
        amount: "20.50", debit_account_code: "1010", credit_account_code: "3000"
      }
    }
    assert_redirected_to journal_voucher_path(document, tenant_id: @org.tenant.id)
    assert_equal "Updated purpose", document.reload.narration
    assert_equal [ 2_050, -2_050 ], document.document_lines.order(:line_no).pluck(:amount_minor)

    assert_difference -> { Document.where(id: document.id).count }, -1 do
      delete journal_voucher_path(document)
    end
    assert_redirected_to journal_vouchers_path(tenant_id: @org.tenant.id)
  end

  test "account creation and team invitations stay permission scoped" do
    assert_difference "Account.count", 1 do
      post accounts_path, params: {
        account: { code: "5300", name: "Professional fees", account_type: "expense" }
      }
    end
    assert_redirected_to accounts_path(tenant_id: @org.tenant.id)

    assert_difference "Invitation.count", 1 do
      post invitations_path, params: { email: "new-member@x.com", role_code: "viewer" }
    end
    invitation = Invitation.order(:id).last
    assert_equal "queued", invitation.delivery_state
    assert_redirected_to team_path(tenant_id: @org.tenant.id)

    invitation.update!(delivery_state: "failed", delivery_attempted_at: 2.minutes.ago)
    get team_path
    assert_response :success
    assert_select ".status-badge--danger", "Delivery failed"
    post resend_invitation_path(invitation)
    assert_redirected_to team_path(tenant_id: @org.tenant.id)
    assert_equal "queued", invitation.reload.delivery_state
  end

  test "owner edits and deactivates an account with an audit trail" do
    account = Account.find_by!(tenant_id: @org.tenant.id, code: "5100")

    assert_difference -> { LedgerEvent.for_tenant(@org.tenant.id).count }, 1 do
      patch account_path(account), params: {
        account: { code: "5100", name: "Operating expenses", account_type: "expense" }
      }
    end
    assert_redirected_to accounts_path(tenant_id: @org.tenant.id)
    assert_equal "Operating expenses", account.reload.name

    patch deactivate_account_path(account)
    assert_redirected_to accounts_path(tenant_id: @org.tenant.id)
    refute account.reload.active?

    get new_journal_voucher_path
    assert_response :success
    assert_select "option[value='5100']", count: 0
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]
  end

  test "owner posts opening balances and reaches a balanced balance sheet" do
    cash = Account.find_by!(tenant_id: @org.tenant.id, code: "1000")
    capital = Account.find_by!(tenant_id: @org.tenant.id, code: "3000")

    assert_difference "Document.count", 1 do
      post opening_balances_path, params: {
        opening_balance: {
          posting_date: "2026-04-01",
          narration: "Migration cutover",
          lines: {
            cash.id.to_s => { debit: "2500.00", credit: "" },
            capital.id.to_s => { debit: "", credit: "2500.00" }
          }
        }
      }
    end
    document = Document.order(:id).last
    assert_redirected_to opening_balance_path(document, tenant_id: @org.tenant.id)

    follow_redirect!
    assert_select "h2", "Balanced and ready to post"
    post post_opening_balance_path(document)
    assert_redirected_to balance_sheet_report_path(
      tenant_id: @org.tenant.id, as_of: "2026-04-01"
    )
    follow_redirect!
    assert_select "h1", "Balance sheet"
    assert_select "tfoot", text: /Balanced/
    assert_equal 0, Entry.find(document.reload.posted_entry_id).period_no
  end

  test "opening balances reject income and expense accounts" do
    cash = Account.find_by!(tenant_id: @org.tenant.id, code: "1000")
    income = Account.find_by!(tenant_id: @org.tenant.id, code: "4000")

    assert_no_difference "Document.count" do
      post opening_balances_path, params: {
        opening_balance: {
          posting_date: "2026-04-01",
          lines: {
            cash.id.to_s => { debit: "100.00", credit: "" },
            income.id.to_s => { debit: "", credit: "100.00" }
          }
        }
      }
    end

    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Couldn't find Account/
  end

  test "verification failure is visible and can be re-queued" do
    @org.user.update!(verification_delivery_state: "failed")

    get root_path
    assert_response :success
    assert_select ".verification-panel", text: /Delivery failed/
    assert_select "button", "Resend verification"

    post verification_delivery_path
    assert_redirected_to root_path(tenant_id: @org.tenant.id)
    assert_equal "queued", @org.user.reload.verification_delivery_state
  end

  test "invoice and settlement prerequisites use ordered progressive disclosure" do
    get new_sales_invoice_path
    assert_response :success
    assert_select "h2", "Finish invoice setup"
    assert_select ".setup-checklist li", count: 4
    assert_select "a.button--primary", text: /Continue setup: Company details/
    assert_select "form[action='#{sales_invoices_path}']", count: 0

    get new_purchase_bill_path
    assert_response :success
    assert_select "h2", "Finish purchase setup"
    assert_select ".setup-checklist li", count: 4
    assert_select "a.button--primary", text: /Continue setup: Company details/
    assert_select "form[action='#{purchase_bills_path}']", count: 0

    get new_settlement_path(kind: "receipt")
    assert_response :success
    assert_select "h2", "No open receivables"
    assert_select "form[action='#{settlements_path}']", count: 0
  end

  test "viewer sees reports but cannot create accounts or vouchers" do
    viewer = Onboarding::Invite.accept!(
      token: Onboarding::Invite.create!(
        tenant: @org.tenant, email: "browser-viewer@x.com", role_code: "viewer", invited_by: @org.user
      ).generate_token_for(:invite),
      password: "correct-horse-battery"
    )
    sign_out
    sign_in_as(viewer)

    get root_path
    assert_response :success
    assert_select "a", text: "Choose your first business event", count: 0
    assert_select "a", "Reports"
    assert_select "a", text: "Team", count: 0

    assert_no_difference "Document.count" do
      get new_journal_voucher_path
    end
    assert_redirected_to root_path(tenant_id: @org.tenant.id)

    assert_no_difference "Account.count" do
      post accounts_path, params: {
        account: { code: "9999", name: "Forbidden", account_type: "expense" }
      }
    end
    assert_redirected_to root_path(tenant_id: @org.tenant.id)
  end
end
