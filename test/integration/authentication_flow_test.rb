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
      email: "authenticated@x.com", password: "correct-horse-battery", org_name: "Authenticated Books"
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

  test "login after an unauthenticated post returns to the referring page, not the post-only action" do
    org = Onboarding::SignUp.call(
      email: "post-return@x.com", password: "correct-horse-battery", org_name: "Post Return Books"
    )
    return_url = security_url(tenant_id: org.tenant.id)

    post invitations_path(tenant_id: org.tenant.id),
      params: { email: "ignored@folio.invalid", role_code: "viewer" },
      headers: { "HTTP_REFERER" => return_url }
    assert_redirected_to new_session_path

    post session_path, params: { email_address: org.user.email_address, password: "correct-horse-battery" }
    assert_redirected_to return_url
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
    assert_match "style-src 'self'", response.headers.fetch("Content-Security-Policy")
    refute_match "unsafe-inline", response.headers.fetch("Content-Security-Policy")
    javascript = Rails.root.join("app/javascript/application.js").read
    assert_includes javascript, "progressBarDelay = 60_000"
    assert_includes javascript, 'classList.add("turbo-loading")'

    get "/favicon.ico"
    assert_redirected_to "/icon.png"
  end
end
