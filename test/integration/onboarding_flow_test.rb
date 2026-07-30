# frozen_string_literal: true

require "test_helper"

# Onboarding over HTTP: self-signup creates an org and logs in; only an owner can invite;
# invite → accept joins the invitee and logs them in.
class OnboardingFlowTest < ActionDispatch::IntegrationTest
  test "self-signup creates an org, seeds books, and logs the user in" do
    assert_difference [ "Tenant.count", "User.count" ], 1 do
      post registration_path, params: { org_name: "Acme Co", email_address: "founder@acme.com", password: "password123" }
    end
    assert_redirected_to root_path
    follow_redirect!
    assert_response :success, "signed in, on the authenticated landing"
    tenant = Tenant.find_by(slug: "acme-co")
    assert_equal 9, Account.where(tenant_id: tenant.id).count, "starter COA seeded"
    assert_equal "queued", User.find_by!(email_address: "founder@acme.com").verification_delivery_state
  end

  test "signup provisions the accounting profile the user confirmed" do
    post registration_path, params: {
      org_name: "Pacific Co",
      email_address: "founder@pacific.example",
      password: "password123",
      jurisdiction_profile: "US",
      functional_currency: "USD",
      fiscal_year_variant: "CAL"
    }

    assert_redirected_to root_path
    tenant = Tenant.find_by!(slug: "pacific-co")
    entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
    assert_equal "USD", tenant.functional_currency
    assert_equal "US", entity.jurisdiction_profile
    assert_equal "CAL", entity.fiscal_year_variant
    assert Account.where(tenant_id: tenant.id).exists?(code: "2100", name: "Tax Payable")
  end

  test "unsupported accounting defaults are rejected without creating a company" do
    assert_no_difference [ "Tenant.count", "User.count" ] do
      post registration_path, params: {
        org_name: "Unknown Co",
        email_address: "unknown@example.com",
        password: "password123",
        jurisdiction_profile: "ZZ",
        functional_currency: "USD",
        fiscal_year_variant: "CAL"
      }
    end

    assert_response :unprocessable_entity
    assert_select "[role=alert]", "Jurisdiction profile is not supported"
    assert_select "input[name=org_name][value='Unknown Co']"
  end

  test "signup with a duplicate email is rejected and creates no org" do
    User.create!(email_address: "taken@x.com", password: "password123")
    assert_no_difference "Tenant.count" do
      post registration_path, params: { org_name: "X", email_address: "taken@x.com", password: "password123" }
    end
    assert_response :unprocessable_entity
    assert_select "[role=alert]", "Email address has already been taken"
    assert_select "input[name=org_name][value=X]"
    assert_select "input[name=email_address][value='taken@x.com']"
    assert_select "input[name=password][value]", count: 0
  end

  test "only an owner can send an invitation; a non-owner is forbidden" do
    org = Onboarding::SignUp.call(email: "owner@x.com", password: "password123", org_name: "Org")
    operator = Onboarding::Invite.accept!(
      token: Onboarding::Invite.create!(tenant: org.tenant, email: "op@x.com", role_code: "operator",
        invited_by: org.user).generate_token_for(:invite), password: "password123")

    sign_in_as(org.user)
    assert_difference "Invitation.count", 1 do
      post invitations_path, params: { email: "new@x.com", role_code: "accountant" }
    end

    sign_out
    sign_in_as(operator)
    assert_no_difference "Invitation.count" do
      post invitations_path, params: { email: "sneaky@x.com", role_code: "owner" }
    end
    assert_response :forbidden, "an operator cannot invite users"
  end

  test "invite → accept joins the invitee with the assigned role and logs them in" do
    org = Onboarding::SignUp.call(email: "o@x.com", password: "password123", org_name: "Org")
    inv = Onboarding::Invite.create!(tenant: org.tenant, email: "joiner@x.com", role_code: "viewer", invited_by: org.user)
    token = inv.generate_token_for(:invite)

    get accept_invitation_path(token)
    assert_response :success

    assert_difference "User.count", 1 do
      post accept_invitation_path(token), params: { password: "password123" }
    end
    assert_redirected_to root_path
    joiner = User.find_by(email_address: "joiner@x.com")
    assert_equal [ org.tenant.id ], joiner.tenants.pluck(:id)
  end

  test "accepting an invite with a blank password re-renders, not a 500" do
    org = Onboarding::SignUp.call(email: "o3@x.com", password: "password123", org_name: "Org3")
    token = Onboarding::Invite.create!(tenant: org.tenant, email: "j3@x.com", role_code: "viewer",
      invited_by: org.user).generate_token_for(:invite)
    post accept_invitation_path(token), params: { password: "" }
    assert_redirected_to accept_invitation_path(token)
    assert_nil User.find_by(email_address: "j3@x.com")
  end

  test "the email-verification link marks the user verified" do
    user = User.create!(email_address: "v@x.com", password: "password123")
    get verify_email_path(user.generate_token_for(:email_verification))
    assert user.reload.verified?
  end

  test "an existing account must authenticate before accepting an invitation" do
    org = Onboarding::SignUp.call(email: "owner-existing@x.com", password: "password123", org_name: "Org")
    existing = User.create!(email_address: "existing@x.com", password: "existing-password")
    invitation = Onboarding::Invite.create!(
      tenant: org.tenant, email: existing.email_address, role_code: "accountant", invited_by: org.user
    )
    token = invitation.generate_token_for(:invite)

    assert_no_difference "Membership.count" do
      post accept_invitation_path(token), params: { password: "wrong-password" }
    end
    assert_redirected_to accept_invitation_path(token)

    assert_difference "Membership.count", 1 do
      post accept_invitation_path(token), params: { password: "existing-password" }
    end
    assert_redirected_to root_path
    follow_redirect!
    assert_response :success
    assert_select "body", text: /Signed in as #{Regexp.escape(existing.email_address)}/
  end
end
