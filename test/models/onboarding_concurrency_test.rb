# frozen_string_literal: true

require "test_helper"
require "securerandom"

# Competing database connections for the signup/invite uniqueness and single-use gates.
class OnboardingConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    tenant_ids = Array(@created_tenant_ids)
    user_ids = Array(@created_user_ids)
    role_ids = RoleTemplate.where(tenant_id: tenant_ids).pluck(:id)

    # These tests deliberately commit across competing connections. Their exact, test-owned
    # teardown must bypass the production last-owner trigger while removing the whole tenant;
    # ordinary application writes never enter this block.
    ActiveRecord::Base.connection.disable_referential_integrity do
      Invitation.where(tenant_id: tenant_ids).delete_all
      UserOfficeRole.where(tenant_id: tenant_ids).delete_all
      RolePermission.where(role_template_id: role_ids).delete_all
      RoleTemplate.where(id: role_ids).delete_all
      Membership.where(tenant_id: tenant_ids).delete_all
      FinancialStatementAssignment.where(tenant_id: tenant_ids).delete_all
      FinancialStatementSection.where(tenant_id: tenant_ids).delete_all
      FinancialStatementVersion.where(tenant_id: tenant_ids).delete_all
      Account.where(tenant_id: tenant_ids).delete_all
      DocumentType.where(tenant_id: tenant_ids).delete_all
      Office.where(tenant_id: tenant_ids).delete_all
      Entity.where(tenant_id: tenant_ids).delete_all
      Ledger.where(tenant_id: tenant_ids).delete_all
      Tenant.where(id: tenant_ids).delete_all
      Session.where(user_id: user_ids).delete_all
      User.where(id: user_ids).delete_all
    end
  end

  def race
    ready = Queue.new
    start = Queue.new
    outcomes = Array.new(2)
    threads = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          outcomes[index] = yield(index)
        rescue StandardError => e
          outcomes[index] = e
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each(&:join)
    outcomes
  end

  test "simultaneous signups with the same company name receive unique slugs" do
    token = SecureRandom.hex(8)
    outcomes = race do |index|
      Onboarding::SignUp.call(
        email: "slug-#{token}-#{index}@x.com",
        password: "correct-horse-battery",
        org_name: "Concurrent #{token}"
      )
    end

    results = outcomes.grep(Onboarding::SignUp::Result)
    @created_tenant_ids = results.map { |result| result.tenant.id }
    @created_user_ids = results.map { |result| result.user.id }
    assert_equal 2, results.size, outcomes.map { |outcome| outcome.class.name }.inspect
    slugs = results.map { |result| result.tenant.slug }
    assert_equal 2, slugs.uniq.size
    assert_includes slugs, "concurrent-#{token}"
    assert_includes slugs, "concurrent-#{token}-2"
  end

  test "simultaneous claims accept an invitation exactly once" do
    token = SecureRandom.hex(8)
    org = Onboarding::SignUp.call(
      email: "invite-owner-#{token}@x.com",
      password: "correct-horse-battery",
      org_name: "Invite concurrency #{token}"
    )
    @created_tenant_ids = [ org.tenant.id ]
    @created_user_ids = [ org.user.id ]
    invitation = Onboarding::Invite.create!(
      tenant: org.tenant,
      email: "invitee-#{token}@x.com",
      role_code: "viewer",
      invited_by: org.user
    )
    signed_token = invitation.generate_token_for(:invite)

    outcomes = race do
      Onboarding::Invite.accept!(token: signed_token, password: "correct-horse-battery")
    end

    assert_equal 1, outcomes.count { |outcome| outcome.is_a?(User) }
    assert_equal [ Onboarding::Invite::AlreadyAccepted ], outcomes.grep(Exception).map(&:class)
    user = User.find_by!(email_address: invitation.email)
    @created_user_ids << user.id
    assert_equal 1, Membership.where(user: user, tenant: org.tenant).count
    assert_equal 1, UserOfficeRole.where(user: user, tenant_id: org.tenant.id, office_id: nil).count
    assert invitation.reload.accepted_at
  end
end
