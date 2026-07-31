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
    assert_select "a", "Record your first transaction"
    assert_select "a", "Chart of accounts"
    assert_select "details.mobile-user-menu button", "Sign out"

    assert_difference "Document.count", 1 do
      post journal_vouchers_path, params: {
        journal_voucher: {
          posting_date: "2026-07-30",
          narration: "Owner capital introduced",
          amount: "1250.50",
          debit_account_code: "1000",
          credit_account_code: "3000"
        }
      }
    end
    document = Document.order(:id).last
    assert_redirected_to journal_voucher_path(document, tenant_id: @org.tenant.id)

    follow_redirect!
    assert_select "h2", "Balanced and ready to post"
    assert_select "td", text: "INR 1,250.50", count: 4

    post post_journal_voucher_path(document, tenant_id: @org.tenant.id)
    assert_redirected_to reports_path(tenant_id: @org.tenant.id, posted_document_id: document.id)
    follow_redirect!
    assert_select "h1", "Trial balance"
    assert_select "[role=status]", text: /posted.*trial balance/i
    assert_select "tr.table-row--highlight", 2
    assert_equal "posted", document.reload.state
  end

  test "account creation and team invitations stay permission scoped" do
    assert_difference "Account.count", 1 do
      post accounts_path, params: {
        account: { code: "5200", name: "Professional fees", account_type: "expense" }
      }
    end
    assert_redirected_to accounts_path(tenant_id: @org.tenant.id)

    assert_difference "Invitation.count", 1 do
      post invitations_path, params: { email: "new-member@x.com", role_code: "viewer" }
    end
    invitation = Invitation.order(:id).last
    assert_equal "queued", invitation.delivery_state
    assert_redirected_to team_path(tenant_id: @org.tenant.id)

    invitation.update!(delivery_state: "failed")
    get team_path
    assert_response :success
    assert_select ".status-badge--danger", "Delivery failed"
    post resend_invitation_path(invitation)
    assert_redirected_to team_path(tenant_id: @org.tenant.id)
    assert_equal "queued", invitation.reload.delivery_state
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
    assert_select "a", text: "Record your first transaction", count: 0
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
