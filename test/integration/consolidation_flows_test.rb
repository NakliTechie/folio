# frozen_string_literal: true

require "test_helper"

class ConsolidationFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "consolidation-browser@folio.invalid", password: "correct-horse-battery",
      org_name: "Consolidation Browser"
    )
    @group = ConsolidationGroup.find_by!(tenant_id: @org.tenant.id, code: "GROUP")
    @seller = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    sign_in_as(@org.user)
  end

  test "owner adds an entity posts both sides and eliminates internal activity" do
    get consolidation_path
    assert_response :success
    assert_select "h1", "Consolidation"
    assert_select ".status-badge", "INR"

    post create_entity_consolidation_path, params: {
      entity: {
        code: "SUB", legal_name: "Browser Subsidiary", office_name: "Subsidiary Office",
        effective_from: "2026-04-01"
      }
    }
    buyer = Entity.find_by!(tenant_id: @org.tenant.id, code: "SUB")
    assert_redirected_to consolidation_path(tenant_id: @org.tenant.id)

    assert_difference "IntercompanyTransaction.count", 1 do
      post post_intercompany_consolidation_path, params: {
        intercompany_transaction: {
          seller_entity_id: @seller.id, buyer_entity_id: buyer.id,
          posting_date: "2026-08-01", amount: "100", description: "Shared services",
          seller_receivable_account_code: "1200", seller_revenue_account_code: "4000",
          buyer_expense_account_code: "5100", buyer_payable_account_code: "2000",
          idempotency_key: "browser-intercompany"
        }
      }
    end
    transaction = IntercompanyTransaction.find_by!(tenant_id: @org.tenant.id)
    assert_redirected_to consolidation_path(tenant_id: @org.tenant.id)
    follow_redirect!
    assert_select "table", text: /IC\/20260801\/.*PRIMARY → SUB.*INR 100\.00/m
    assert_select "table", text: /Sundry Debtors.*INR 100\.00.*INR 0\.00.*INR 100\.00/m

    assert_difference "ConsolidationEliminationRun.count", 1 do
      post eliminate_consolidation_path, params: {
        id: transaction.id, posting_date: "2026-08-31", idempotency_key: "browser-elimination"
      }
    end
    assert_redirected_to consolidation_path(tenant_id: @org.tenant.id, as_of: Date.new(2026, 8, 31))
    follow_redirect!
    assert_select ".status-badge", "Eliminated"
    assert_select "table", text: /Sundry Debtors.*INR 100\.00.*INR -100\.00.*INR 0\.00/m
  end

  test "viewer reads group evidence without management or posting controls" do
    viewer = invite_user("consolidation-browser-viewer@folio.invalid", "viewer")
    sign_out
    sign_in_as(viewer)

    get consolidation_path
    assert_response :success
    assert_select "h1", "Consolidation"
    assert_select "form[action='#{create_entity_consolidation_path}']", count: 0
    assert_select "form[action='#{post_intercompany_consolidation_path}']", count: 0
    assert_no_difference "Entity.count" do
      post create_entity_consolidation_path, params: {
        entity: { code: "NOPE", legal_name: "Denied" }
      }
    end
    assert_redirected_to root_path(tenant_id: @org.tenant.id)
  end

  private

  def invite_user(email, role_code)
    invitation = Onboarding::Invite.create!(
      tenant: @org.tenant, email: email, role_code: role_code, invited_by: @org.user
    )
    Onboarding::Invite.accept!(
      token: invitation.generate_token_for(:invite), password: "correct-horse-battery"
    )
  end
end
