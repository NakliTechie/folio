# frozen_string_literal: true

require "test_helper"

class SecuritySessionsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "session-owner@example.com", password: "correct-horse-battery", org_name: "Session Books"
    )
    sign_in_as(@org.user)
    @current_session = Current.session
    @other_session = @org.user.sessions.create!(user_agent: "Other browser", ip_address: "192.0.2.1")
  end

  test "a user can review and revoke another active session" do
    get security_path(tenant_id: @org.tenant.id)

    assert_response :success
    assert_select "h1", "Signed-in devices"
    assert_select "tbody tr", 2

    delete active_session_path(@other_session, tenant_id: @org.tenant.id)

    assert_redirected_to security_path(tenant_id: @org.tenant.id)
    assert_not Session.exists?(@other_session.id)
    assert Session.exists?(@current_session.id)
  end

  test "revoking the current session signs out this device" do
    delete active_session_path(@current_session, tenant_id: @org.tenant.id)

    assert_redirected_to new_session_path
    assert_not Session.exists?(@current_session.id)
    assert_empty cookies[:session_id]
  end
end
