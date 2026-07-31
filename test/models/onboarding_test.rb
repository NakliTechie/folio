# frozen_string_literal: true

require "test_helper"

# Onboarding (both paths) at the service level.
class OnboardingTest < ActiveSupport::TestCase
  test "self-signup creates org + owner + roles + seeded books in one transaction" do
    r = Onboarding::SignUp.call(email: "founder@acme.com", password: "correct-horse-battery", org_name: "Acme Consulting")
    assert r.user.persisted?
    assert_equal "acme-consulting", r.tenant.slug
    assert_includes r.user.tenants, r.tenant
    assert_equal "owner", r.user.user_office_roles.first.role_template.code
    assert_equal 9, Account.where(tenant_id: r.tenant.id).count
    assert Account.where(tenant_id: r.tenant.id).exists?(code: "1000")
    assert DocumentType.where(tenant_id: r.tenant.id).exists?(code: "JV")
    entity = Entity.find_by!(tenant_id: r.tenant.id, code: "PRIMARY")
    assert_equal r.tenant.name, entity.legal_name
    assert_equal entity.id, Office.find_by!(tenant_id: r.tenant.id, code: "PRIMARY").entity_id
    assert Ledger.where(tenant_id: r.tenant.id).exists?(code: "PRIMARY")
    assert_equal 5, RoleTemplate.where(tenant_id: r.tenant.id).count
    assert Authorization.permits?(user: r.user, tenant_id: r.tenant.id, capability: "documents.post"),
      "the new owner can post immediately"
  end

  test "signup slugs de-duplicate across orgs with the same name" do
    a = Onboarding::SignUp.call(email: "a@x.com", password: "correct-horse-battery", org_name: "Dup Co")
    b = Onboarding::SignUp.call(email: "b@x.com", password: "correct-horse-battery", org_name: "Dup Co")
    assert_equal "dup-co", a.tenant.slug
    assert_equal "dup-co-2", b.tenant.slug
  end

  test "signup is atomic — a failing signup creates no org" do
    Onboarding::SignUp.call(email: "taken@x.com", password: "correct-horse-battery", org_name: "First")
    before = Tenant.count
    assert_raises(ActiveRecord::RecordInvalid) do
      Onboarding::SignUp.call(email: "taken@x.com", password: "correct-horse-battery", org_name: "Second")
    end
    assert_equal before, Tenant.count, "a failed signup rolls back the whole org"
  end

  test "invite → accept adds a member with the assigned role, isolated to that tenant" do
    org = Onboarding::SignUp.call(email: "owner@x.com", password: "correct-horse-battery", org_name: "Org")
    inv = Onboarding::Invite.create!(tenant: org.tenant, email: "clerk@x.com", role_code: "operator", invited_by: org.user)
    user = Onboarding::Invite.accept!(token: inv.generate_token_for(:invite), password: "correct-horse-battery")

    assert user.persisted?
    assert_equal "operator", user.user_office_roles.first.role_template.code
    assert_equal [ org.tenant.id ], user.tenants.pluck(:id), "the new member sees ONLY the inviting tenant"
    refute Authorization.permits?(user: user, tenant_id: org.tenant.id, capability: "documents.post"),
      "an operator cannot post (role enforced)"
  end

  test "an invitation is single-use and an invalid token yields nil" do
    org = Onboarding::SignUp.call(email: "o2@x.com", password: "correct-horse-battery", org_name: "Org2")
    inv = Onboarding::Invite.create!(tenant: org.tenant, email: "c2@x.com", role_code: "viewer", invited_by: org.user)
    token = inv.generate_token_for(:invite)
    Onboarding::Invite.accept!(token: token, password: "correct-horse-battery")
    assert_raises(Onboarding::Invite::AlreadyAccepted) { Onboarding::Invite.accept!(token: token, password: "correct-horse-battery") }
    assert_nil Onboarding::Invite.accept!(token: "garbage", password: "correct-horse-battery")
  end

  test "email verification marks the user verified via a signed token" do
    u = User.create!(email_address: "v@x.com", password: "correct-horse-battery")
    refute u.verified?
    found = User.find_by_token_for(:email_verification, u.generate_token_for(:email_verification))
    assert_equal u, found
    found.verify!
    assert u.reload.verified?
  end

  test "an accepted invite explicitly updates an existing tenant role" do
    org = Onboarding::SignUp.call(email: "role-owner@x.com", password: "correct-horse-battery", org_name: "Org")
    existing = Onboarding::Invite.accept!(
      token: Onboarding::Invite.create!(
        tenant: org.tenant, email: "role-member@x.com", role_code: "viewer", invited_by: org.user
      ).generate_token_for(:invite),
      password: "correct-horse-battery"
    )
    invitation = Onboarding::Invite.create!(
      tenant: org.tenant, email: existing.email_address, role_code: "accountant", invited_by: org.user
    )

    Onboarding::Invite.accept!(
      token: invitation.generate_token_for(:invite),
      password: "correct-horse-battery"
    )

    assignment = UserOfficeRole.find_by!(user: existing, tenant_id: org.tenant.id, office_id: nil)
    assert_equal "accountant", assignment.role_template.code
  end

  test "only one pending invitation can exist for an email in a tenant" do
    org = Onboarding::SignUp.call(email: "unique-owner@x.com", password: "correct-horse-battery", org_name: "Org")
    Onboarding::Invite.create!(
      tenant: org.tenant, email: "pending@x.com", role_code: "viewer", invited_by: org.user
    )

    error = assert_raises(ActiveRecord::RecordInvalid) do
      Onboarding::Invite.create!(
        tenant: org.tenant, email: "PENDING@x.com", role_code: "accountant", invited_by: org.user
      )
    end
    assert_includes error.record.errors.full_messages, "Email already has a pending invitation"
  end
end
