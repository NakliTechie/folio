# frozen_string_literal: true

require "test_helper"

# M2.2 — the load-bearing tenancy invariant: a user reaches ONLY their own tenant(s), never
# another's, no matter what tenant selector they send.
class Api::V1::TenantIsolationTest < ActionDispatch::IntegrationTest
  setup do
    @alice = User.create!(email_address: "alice@x.com", password: "correct-horse-battery")
    @acme = Tenant.create!(name: "Acme", slug: "acme")
    @globex = Tenant.create!(name: "Globex", slug: "globex")
    Membership.create!(user: @alice, tenant: @acme)
    # @globex has a different member — @alice must never reach it.
    Membership.create!(user: User.create!(email_address: "bob@x.com", password: "correct-horse-battery"), tenant: @globex)
  end

  test "an unauthenticated API request gets 401 JSON, not an HTML redirect" do
    get "/api/v1/tenant"
    assert_response :unauthorized
    assert_equal "authentication required", JSON.parse(response.body)["error"]
  end

  test "an authenticated user resolves their OWN tenant" do
    sign_in_as(@alice)
    get "/api/v1/tenant"
    assert_response :success
    assert_equal @acme.id, JSON.parse(response.body).dig("tenant", "id")
  end

  test "a user CANNOT resolve a tenant they are not a member of — the selector picks only among their own" do
    sign_in_as(@alice)
    get "/api/v1/tenant", headers: { "X-Tenant" => @globex.id.to_s }
    assert_response :forbidden
    assert_nil JSON.parse(response.body)["tenant"], "Globex must never be served to a non-member"
  end

  test "a user with no membership is forbidden (no default tenant leaks in)" do
    sign_in_as(User.create!(email_address: "charlie@x.com", password: "correct-horse-battery"))
    get "/api/v1/tenant"
    assert_response :forbidden
  end
end
