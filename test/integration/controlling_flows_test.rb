# frozen_string_literal: true

require "test_helper"

class ControllingFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "controlling-browser@folio.invalid", password: "correct-horse-battery",
      org_name: "Controlling Browser"
    )
    sign_in_as(@org.user)
  end

  test "owner builds a hierarchy, assigns an expense, plans, and allocates it" do
    get controlling_path
    assert_response :success
    assert_select "h1", "Controlling"

    post create_segment_controlling_path, params: {
      controlling_segment: { code: "MFG", name: "Manufacturing" }
    }
    segment = ControllingSegment.find_by!(tenant_id: @org.tenant.id, code: "MFG")
    post create_profit_center_controlling_path, params: {
      profit_center: {
        code: "OPS", name: "Operations", controlling_segment_id: segment.id,
        valid_from: "2026-04-01"
      }
    }
    profit = ProfitCenter.find_by!(tenant_id: @org.tenant.id, code: "OPS")
    %w[ADMIN FACTORY].each do |code|
      post create_cost_center_controlling_path, params: {
        cost_center: {
          code: code, name: code.humanize, profit_center_id: profit.id, valid_from: "2026-04-01"
        }
      }
    end
    admin = CostCenter.find_by!(tenant_id: @org.tenant.id, code: "ADMIN")
    factory = CostCenter.find_by!(tenant_id: @org.tenant.id, code: "FACTORY")

    post journal_vouchers_path, params: {
      journal_voucher: {
        event_kind: "expense", posting_date: "2026-08-10", currency: "INR", amount: "100",
        expense_account_code: "5100", cash_account_code: "1000",
        narration: "Admin supplies", cost_center_id: admin.id
      }
    }
    document = Document.where(tenant_id: @org.tenant.id, doc_type: "JV").order(:id).last
    post post_journal_voucher_path(document)
    assert document.reload.posted?
    assert_equal admin.id, Entry.find(document.posted_entry_id).entry_lines
      .find_by!(account_code: "5100").cost_object_id

    post create_plan_controlling_path, params: {
      controlling_plan: {
        cost_center_id: admin.id, account_code: "5100", version: "BUDGET",
        fiscal_year: 2026, period_no: 5, amount: "125"
      }
    }
    assert_equal 12_500, ControllingPlanLine.find_by!(tenant_id: @org.tenant.id).amount_minor

    post create_cycle_controlling_path, params: {
      allocation_cycle: {
        code: "ADMIN-OH", name: "Admin overhead", sender_cost_center_id: admin.id,
        source_account_code: "5100", valid_from: "2026-04-01",
        receiver_1_id: factory.id, receiver_1_weight: "100"
      }
    }
    cycle = AllocationCycle.find_by!(tenant_id: @org.tenant.id, code: "ADMIN-OH")
    post run_allocation_controlling_path, params: {
      id: cycle.id, through_date: "2026-08-31", posting_date: "2026-08-31",
      mode: "post", idempotency_key: "browser-allocation"
    }
    assert_redirected_to controlling_path(tenant_id: @org.tenant.id)
    assert_equal 10_000, AllocationRun.find_by!(tenant_id: @org.tenant.id).allocated_amount_minor
    follow_redirect!
    assert_select "table", text: /ADMIN.*OPS.*MFG/m
    assert_select "table", text: /BUDGET.*2026\/5.*INR 125.00.*INR 0.00/m
  end

  test "viewer can read controlling reports but cannot mutate them" do
    viewer = invite_user("controlling-viewer@folio.invalid", "viewer")
    sign_out
    sign_in_as(viewer)

    get controlling_path
    assert_response :success
    %w[create_segment create_profit_center create_cost_center create_plan create_cycle].each do |action|
      assert_select "form[action='#{public_send("#{action}_controlling_path")}']", count: 0
    end
    assert_no_difference "CostCenter.count" do
      post create_cost_center_controlling_path, params: { cost_center: { code: "NOPE" } }
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
