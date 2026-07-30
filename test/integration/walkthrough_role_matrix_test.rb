# frozen_string_literal: true

require "test_helper"

class WalkthroughRoleMatrixTest < ActionDispatch::IntegrationTest
  PASSWORD = "walkthrough-password-2026"

  setup do
    @org = Onboarding::SignUp.call(
      email: "matrix-owner@folio.invalid", password: PASSWORD, org_name: "Matrix Books"
    )
    @users = { "owner" => @org.user }
    Rbac::Presets::MATRIX.each_key do |role_code|
      next if role_code == "owner"

      invitation = Onboarding::Invite.create!(
        tenant: @org.tenant, email: "matrix-#{role_code.tr("_", "-")}@folio.invalid",
        role_code: role_code, invited_by: @org.user
      )
      @users[role_code] = Onboarding::Invite.accept!(
        token: invitation.generate_token_for(:invite), password: PASSWORD
      )
    end
  end

  def jv_params
    {
      doc_type: "JV", fiscal_year: 2025, document_date: "2025-06-01", posting_date: "2025-06-01",
      lines: [
        { account_code: "1000", amount_minor: 100_000 },
        { account_code: "4000", amount_minor: -100_000 }
      ]
    }
  end

  def as_role(role_code)
    sign_in_as(@users.fetch(role_code))
    yield
  ensure
    sign_out
  end

  test "all presets can read reports" do
    @users.each_key do |role_code|
      as_role(role_code) do
        get "/api/v1/reports/trial_balance"
        assert_response :success, "#{role_code} should have reports.read"
      end
    end
  end

  test "account management follows the preset matrix" do
    allowed = %w[owner accountant]
    @users.each_key.with_index do |role_code, index|
      as_role(role_code) do
        post "/api/v1/accounts",
          params: { code: "9#{index.to_s.rjust(3, "0")}", name: "#{role_code} probe", account_type: "expense" }
        assert_response allowed.include?(role_code) ? :created : :forbidden
      end
    end
  end

  test "document creation and preview follow the preset matrix" do
    allowed_to_create = %w[owner accountant ca_auditor]
    @users.each_key do |role_code|
      as_role(role_code) do
        post "/api/v1/documents", params: jv_params
        assert_response allowed_to_create.include?(role_code) ? :created : :forbidden
      end
    end

    as_role("owner") do
      post "/api/v1/documents", params: jv_params
      @document_id = JSON.parse(response.body).dig("document", "id")
    end

    allowed_to_preview = %w[owner accountant operator ca_auditor]
    @users.each_key do |role_code|
      as_role(role_code) do
        post "/api/v1/documents/#{@document_id}/simulate"
        assert_response allowed_to_preview.include?(role_code) ? :success : :forbidden
      end
    end
  end

  test "only owner can invite and another tenant stays opaque" do
    @users.each_key.with_index do |role_code, index|
      as_role(role_code) do
        post invitations_path,
          params: { email: "invited-#{index}@folio.invalid", role_code: "viewer" }
        assert_response role_code == "owner" ? :redirect : :forbidden
      end
    end

    other = Onboarding::SignUp.call(
      email: "other-owner@folio.invalid", password: PASSWORD, org_name: "Other Books"
    )
    foreign_account = Account.find_by!(tenant_id: other.tenant.id, code: "1000")
    as_role("owner") do
      get "/api/v1/accounts/#{foreign_account.id}"
      assert_response :not_found
    end
  end
end
