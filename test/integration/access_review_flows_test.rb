# frozen_string_literal: true

require "test_helper"

class AccessReviewFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "grc-browser-owner@folio.invalid", password: "correct-horse-battery",
      org_name: "GRC Browser"
    )
    @auditor = invite_user("grc-browser-auditor@folio.invalid", "ca_auditor")
    @viewer = invite_user("grc-browser-viewer@folio.invalid", "viewer")
    sign_in_as(@org.user)
  end

  test "owner captures and attests an access review in the browser" do
    get access_review_path
    assert_response :success
    assert_select "h1", "Access reviews"
    assert_select "form button", "Capture access review"
    assert_select "table", text: /Critical.*Access administration and financial posting/m

    assert_difference "AccessReviewRun.count", 1 do
      post access_review_path
    end
    assert_redirected_to access_review_path(tenant_id: @org.tenant.id)
    review = AccessReviewRun.where(tenant_id: @org.tenant.id).sole
    follow_redirect!
    assert_select "code", text: /#{review.snapshot_sha256.first(12)}/

    assert_difference "AccessReviewAttestation.count", 1 do
      post attest_access_review_path, params: {
        id: review.id, outcome: "approved",
        notes: "Owner reviewed current conflicts and compensating controls."
      }
    end
    assert_redirected_to access_review_path(tenant_id: @org.tenant.id)
    follow_redirect!
    assert_select ".status-badge", "Approved"
  end

  test "auditor reads evidence without owner controls and viewer is denied" do
    sign_out
    sign_in_as(@auditor)
    get access_review_path
    assert_response :success
    assert_select "h1", "Access reviews"
    assert_select "form button", { text: "Capture access review", count: 0 }
    assert_no_difference "AccessReviewRun.count" do
      post access_review_path
    end
    assert_redirected_to root_path(tenant_id: @org.tenant.id)

    sign_out
    sign_in_as(@viewer)
    get access_review_path
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
