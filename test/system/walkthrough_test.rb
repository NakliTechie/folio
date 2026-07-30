# frozen_string_literal: true

require "application_system_test_case"

class WalkthroughTest < ApplicationSystemTestCase
  PASSWORD = "walkthrough-password-2026"

  test "anonymous signup and duplicate-email recovery" do
    visit root_path
    assert_current_path new_session_path
    assert_selector "h1", text: "Sign in to Folio"

    click_link "Create an account"
    fill_in "Company name", with: "Walkthrough Books"
    fill_in "Email", with: "walkthrough-owner@folio.invalid"
    fill_in "Password", with: PASSWORD
    click_button "Create account"

    assert_current_path root_path
    assert_selector "[role=status]", text: "Welcome to Folio — Walkthrough Books is ready."
    assert_text "Signed in as walkthrough-owner@folio.invalid."

    click_button "Sign out"
    click_link "Create an account"
    fill_in "Company name", with: "Preserved Company"
    fill_in "Email", with: "walkthrough-owner@folio.invalid"
    fill_in "Password", with: PASSWORD
    click_button "Create account"

    assert_selector "[role=alert]", text: "Email address has already been taken"
    assert_field "Company name", with: "Preserved Company"
    assert_field "Email", with: "walkthrough-owner@folio.invalid"
    assert_field "Password", with: ""
  end

  test "every RBAC preset can enter and leave its authenticated landing" do
    org = Onboarding::SignUp.call(
      email: "role-owner@folio.invalid", password: PASSWORD, org_name: "Role Walkthrough"
    )
    users = { "owner" => org.user }
    Rbac::Presets::MATRIX.each_key do |role_code|
      next if role_code == "owner"

      invitation = Onboarding::Invite.create!(
        tenant: org.tenant, email: "role-#{role_code.tr("_", "-")}@folio.invalid",
        role_code: role_code, invited_by: org.user
      )
      users[role_code] = Onboarding::Invite.accept!(
        token: invitation.generate_token_for(:invite), password: PASSWORD
      )
    end

    users.each do |role_code, user|
      visit new_session_path
      fill_in "Email", with: user.email_address
      fill_in "Password", with: PASSWORD
      click_button "Sign in"

      assert_current_path root_path
      assert_text "Signed in as #{user.email_address}.", wait: 5
      click_button "Sign out"
      assert_current_path new_session_path
    end
  end
end
