# frozen_string_literal: true

require "test_helper"

# M2.1 — the auth gate. Protected actions require a session; login/logout work; the health
# endpoint stays open for load balancers.
class AuthenticationFlowTest < ActionDispatch::IntegrationTest
  test "the root requires authentication — an unauthenticated request is redirected to login" do
    get root_path
    assert_redirected_to new_session_path
    follow_redirect!
    assert_select "h1", "Sign in to Folio"
    assert_select "a[href='#{new_registration_path}']", "Create an account"
  end

  test "an authenticated user reaches the root" do
    org = Onboarding::SignUp.call(
      email: "authenticated@x.com", password: "password123", org_name: "Authenticated Books"
    )
    sign_in_as(org.user)
    get root_path
    assert_response :success
    assert_select "h1", "Your books, at a glance"
    assert_select "nav[aria-label='Primary navigation']"
  end

  test "login with the correct password starts a session; a wrong password is rejected" do
    post session_path, params: { email_address: "one@example.com", password: "password" }
    assert_redirected_to root_path

    sign_out
    post session_path, params: { email_address: "one@example.com", password: "WRONG" }
    assert_redirected_to new_session_path, "a wrong password must not authenticate"
    follow_redirect!
    assert_select "[role=alert]", "Try another email address or password."
  end

  test "logout terminates the session" do
    sign_in_as(users(:one))
    delete session_path
    get root_path
    assert_redirected_to new_session_path
  end

  test "the health endpoint is reachable without authentication" do
    get "/up"
    assert_response :success
  end

  test "public pages declare language, description, landmark, CSP, and a conventional favicon" do
    get new_session_path
    assert_response :success
    assert_select "html[lang=en]"
    assert_select "meta[name=description][content]"
    assert_select "main#main-content"
    assert_match "default-src 'self'", response.headers.fetch("Content-Security-Policy")

    get "/favicon.ico"
    assert_redirected_to "/icon.png"
  end
end
