# frozen_string_literal: true

require "test_helper"

class BusinessProfileFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "business-profile-flow@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Business Profile Flow"
    )
    @office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    sign_in_as(@org.user)
  end

  test "owner completes statutory company details in the browser" do
    get edit_business_profile_path
    assert_response :success
    assert_select "h1", "Legal and invoice details"

    assert_difference -> { LedgerEvent.for_tenant(@org.tenant.id).count }, 1 do
      patch business_profile_path, params: profile_params
    end
    assert_redirected_to edit_business_profile_path(tenant_id: @org.tenant.id)
    assert_equal "27", @office.reload.state_code
    assert_equal "400001", @office.postal_code
  end

  test "JSON profile is readable and owner updates are validated and audited" do
    get "/api/v1/business_profile"
    assert_response :success
    assert_equal "Business Profile Flow", JSON.parse(response.body).dig("business_profile", "entity", "legal_name")

    patch "/api/v1/business_profile", params: profile_params.fetch(:business_profile)
    assert_response :success
    json = JSON.parse(response.body).fetch("business_profile")
    assert_equal "Example Services Private Limited", json.dig("entity", "legal_name")
    assert_equal "IN", json.dig("office", "country_code")
    assert_equal "business_profile.updated", LedgerEvent.for_tenant(@org.tenant.id).in_order.last.action
  end

  test "viewer can read but cannot mutate company details" do
    invitation = Onboarding::Invite.create!(
      tenant: @org.tenant, email: "business-profile-viewer@folio.invalid",
      role_code: "viewer", invited_by: @org.user
    )
    viewer = Onboarding::Invite.accept!(
      token: invitation.generate_token_for(:invite), password: "correct-horse-battery"
    )
    sign_out
    sign_in_as(viewer)

    get "/api/v1/business_profile"
    assert_response :success
    assert_no_difference -> { LedgerEvent.for_tenant(@org.tenant.id).count } do
      patch "/api/v1/business_profile", params: profile_params.fetch(:business_profile)
    end
    assert_response :forbidden
    assert_nil @office.reload.address_line1
  end

  private

  def profile_params
    {
      business_profile: {
        entity: { legal_name: "Example Services Private Limited" },
        office: {
          name: "Registered Office", address_line1: "1 Ledger Lane", address_line2: "Fort",
          city: "Mumbai", postal_code: "400001", state_code: "27", country_code: "in"
        }
      }
    }
  end
end
