# frozen_string_literal: true

require "test_helper"

class PeriodCloseFlowsTest < ActionDispatch::IntegrationTest
  PASSWORD = "period-close-password"

  setup do
    @org = Onboarding::SignUp.call(
      email: "period-close-owner@folio.invalid", password: PASSWORD, org_name: "Period Close Flow"
    )
    @posted = build_voucher("Posted July activity")
    Documents::Post.call(@posted, actor: "u:#{@org.user.id}")
    @draft = build_voucher("Draft July adjustment")
    @accountant = invited_user("accountant")
    @auditor = invited_user("ca_auditor")
    sign_in_as(@org.user)
  end

  test "owner reviews readiness and moves the period through audited states" do
    get period_close_path, params: { fiscal_year: 2026, period_no: 4 }
    assert_response :success
    assert_select "h1", "Period close"
    assert_select ".summary-strip", text: /Period 4.*July 2026.*Open.*1.*Review needed/m
    assert_select ".metric-card", text: /Unposted documents.*1/m
    assert_select ".metric-card", text: /Audit chain.*Verified/m

    patch period_close_path, params: {
      period_control: { fiscal_year: 2026, period_no: 4, state: "restricted" }
    }
    assert_redirected_to period_close_path(
      tenant_id: @org.tenant.id, fiscal_year: "2026", period_no: "4"
    )
    control = PeriodControl.find_by!(tenant_id: @org.tenant.id, fiscal_year: 2026, period_no: 4)
    assert_equal "restricted", control.state
    assert_equal "period.lock", control.capability
    assert_equal "period.restricted", LedgerEvent.for_tenant(@org.tenant.id).last.action

    patch "/api/v1/period_close", params: { fiscal_year: 2026, period_no: 4, state: "closed" }
    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "closed", response_body.dig("period_control", "state")
    assert_equal "closed", response_body.dig("period_close", "state")

    patch "/api/v1/period_close", params: { fiscal_year: 2026, period_no: 4, state: "open" }
    assert_response :success
    assert_equal "open", PeriodControl.find(control.id).state
    assert LedgerEvent.verify_chain(@org.tenant.id).fetch(:ok)
  end

  test "restricted posting reaches the role capability and closed posting blocks everyone" do
    patch "/api/v1/period_close", params: { fiscal_year: 2026, period_no: 4, state: "restricted" }
    assert_response :success

    sign_out
    sign_in_as(@accountant)
    post "/api/v1/documents/#{@draft.id}/post"
    assert_response :forbidden
    assert_match(/period\.lock/, JSON.parse(response.body).fetch("error"))
    patch "/api/v1/period_close", params: { fiscal_year: 2026, period_no: 4, state: "closed" }
    assert_response :forbidden

    sign_out
    sign_in_as(@auditor)
    post "/api/v1/documents/#{@draft.id}/post"
    assert_response :success

    sign_out
    sign_in_as(@org.user)
    another_draft = build_voucher("Blocked after close")
    patch "/api/v1/period_close", params: { fiscal_year: 2026, period_no: 4, state: "closed" }
    assert_response :success
    post "/api/v1/documents/#{another_draft.id}/post"
    assert_response :conflict
    assert_match(/period 2026\/4 is closed/, JSON.parse(response.body).fetch("error"))
  end

  test "all report readers see readiness but only close-authorized roles can change state" do
    sign_out
    sign_in_as(@accountant)
    get "/api/v1/period_close", params: { fiscal_year: 2026, period_no: 4 }
    assert_response :success
    assert_equal 1, JSON.parse(response.body).dig("period_close", "draft_document_count")
    patch "/api/v1/period_close", params: { fiscal_year: 2026, period_no: 4, state: "closed" }
    assert_response :forbidden

    sign_out
    sign_in_as(@auditor)
    patch "/api/v1/period_close", params: { fiscal_year: 2026, period_no: 4, state: "restricted" }
    assert_response :success
  end

  private

  def build_voucher(narration)
    Documents::BuildDraft.call(
      tenant: @org.tenant, doc_type: "JV",
      document_date: Date.new(2026, 7, 31), posting_date: Date.new(2026, 7, 31),
      narration: narration,
      lines: [
        { account_code: "1000", amount_minor: 10_000 },
        { account_code: "3000", amount_minor: -10_000 }
      ]
    )
  end

  def invited_user(role_code)
    invitation = Onboarding::Invite.create!(
      tenant: @org.tenant,
      email: "period-close-#{role_code.tr("_", "-")}@folio.invalid",
      role_code: role_code,
      invited_by: @org.user
    )
    Onboarding::Invite.accept!(token: invitation.generate_token_for(:invite), password: PASSWORD)
  end
end
