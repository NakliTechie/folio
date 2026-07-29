# frozen_string_literal: true

require "test_helper"

# API.1 — the core JSON API, exercised for the security-critical paths: auth, per-endpoint
# tenant isolation, RBAC, balance, CSRF, and the full document lifecycle.
class Api::V1::DocumentsApiTest < ActionDispatch::IntegrationTest
  setup do
    @acme = Onboarding::SignUp.call(email: "acme@x.com", password: "password123", org_name: "Acme")
    @globex = Onboarding::SignUp.call(email: "globex@x.com", password: "password123", org_name: "Globex")
  end

  def jv_params(dr: 100_000)
    { doc_type: "JV", fiscal_year: 2025, document_date: "2025-06-01", posting_date: "2025-06-01",
      lines: [ { account_code: "1000", amount_minor: dr }, { account_code: "4000", amount_minor: -dr } ] }
  end

  def create_jv(**over)
    post "/api/v1/documents", params: jv_params(**over)
    JSON.parse(response.body).dig("document", "id")
  end

  test "unauthenticated API requests are 401" do
    get "/api/v1/reports/trial_balance"
    assert_response :unauthorized
    post "/api/v1/documents", params: jv_params
    assert_response :unauthorized
  end

  test "owner: create → simulate → post → trial balance over the API" do
    sign_in_as(@acme.user)
    id = create_jv
    assert_response :created

    post "/api/v1/documents/#{id}/simulate"
    assert_response :success
    assert JSON.parse(response.body)["balanced"]

    post "/api/v1/documents/#{id}/post"
    assert_response :success
    assert_equal "posted", JSON.parse(response.body).dig("document", "state")

    get "/api/v1/reports/trial_balance"
    tb = JSON.parse(response.body)["trial_balance"]
    assert_equal 100_000, tb.find { |r| r["name"] == "Cash" }["debit"]
  end

  test "an unbalanced post is 422" do
    sign_in_as(@acme.user)
    post "/api/v1/documents", params: jv_params.merge(
      lines: [ { account_code: "1000", amount_minor: 100_000 }, { account_code: "4000", amount_minor: -99_999 } ])
    id = JSON.parse(response.body).dig("document", "id")
    post "/api/v1/documents/#{id}/post"
    assert_response :unprocessable_entity
  end

  test "ISOLATION — a user cannot read or post another tenant's document (404)" do
    sign_in_as(@acme.user)
    acme_id = create_jv
    sign_out

    sign_in_as(@globex.user)
    get "/api/v1/documents/#{acme_id}"
    assert_response :not_found
    post "/api/v1/documents/#{acme_id}/post"
    assert_response :not_found
    post "/api/v1/documents/#{acme_id}/reverse"
    assert_response :not_found
  end

  test "ISOLATION — each tenant's trial balance shows only its own postings" do
    sign_in_as(@acme.user)
    id = create_jv
    post "/api/v1/documents/#{id}/post"
    sign_out

    sign_in_as(@globex.user)
    get "/api/v1/reports/trial_balance"
    assert_equal [], JSON.parse(response.body)["trial_balance"], "Globex sees none of Acme's postings"
  end

  test "RBAC — an operator cannot create/post a voucher (403)" do
    op = Onboarding::Invite.accept!(
      token: Onboarding::Invite.create!(tenant: @acme.tenant, email: "op@x.com", role_code: "operator",
        invited_by: @acme.user).generate_token_for(:invite), password: "password123")
    sign_in_as(op)
    post "/api/v1/documents", params: jv_params
    assert_response :forbidden
  end

  test "masters are tenant-scoped; create needs accounts.manage" do
    sign_in_as(@acme.user)
    get "/api/v1/accounts"
    assert_includes JSON.parse(response.body)["accounts"].map { |a| a["code"] }, "1000"
    assert_difference -> { Account.where(tenant_id: @acme.tenant.id).count }, 1 do
      post "/api/v1/accounts", params: { code: "6000", name: "Rent", account_type: "expense" }
    end
    assert_response :created
  end

  test "state-changing API writes are CSRF-protected" do
    sign_in_as(@acme.user)
    ActionController::Base.allow_forgery_protection = true
    post "/api/v1/documents", params: jv_params
    assert_response :unprocessable_entity, "a write without a CSRF token is blocked"
    assert_equal "invalid or missing CSRF token", JSON.parse(response.body)["error"], "and stays JSON"
  ensure
    ActionController::Base.allow_forgery_protection = false
  end
end
