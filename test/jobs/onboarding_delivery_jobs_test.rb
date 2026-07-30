# frozen_string_literal: true

require "test_helper"

class OnboardingDeliveryJobsTest < ActiveJob::TestCase
  class FailingDelivery
    def initialize(_settings)
    end

    def deliver!(_mail)
      raise IOError, "SMTP unavailable"
    end
  end

  setup do
    ActionMailer::Base.deliveries.clear
    ActionMailer::Base.add_delivery_method(:failing_test, FailingDelivery)
  end

  test "verification delivery records success" do
    user = User.create!(
      email_address: "delivery@x.com",
      password: "password123",
      verification_delivery_state: "queued"
    )

    assert_difference "ActionMailer::Base.deliveries.size", 1 do
      VerificationDeliveryJob.perform_now(user.id)
    end

    assert_equal "sent", user.reload.verification_delivery_state
    assert user.verification_delivery_attempted_at
  end

  test "verification delivery records failure before re-raising" do
    user = User.create!(
      email_address: "delivery-failure@x.com",
      password: "password123",
      verification_delivery_state: "queued"
    )
    with_failing_delivery do
      assert_raises(IOError) { VerificationDeliveryJob.perform_now(user.id) }
    end

    assert_equal "failed", user.reload.verification_delivery_state
    assert user.verification_delivery_attempted_at
  end

  test "invitation delivery records success and failure" do
    org = Onboarding::SignUp.call(
      email: "delivery-owner@x.com", password: "password123", org_name: "Delivery Books"
    )
    invitation = Onboarding::Invite.create!(
      tenant: org.tenant,
      email: "invite-delivery@x.com",
      role_code: "viewer",
      invited_by: org.user
    )

    InvitationDeliveryJob.perform_now(invitation.id)
    assert_equal "sent", invitation.reload.delivery_state

    invitation.update!(delivery_state: "queued")
    with_failing_delivery do
      assert_raises(IOError) { InvitationDeliveryJob.perform_now(invitation.id) }
    end
    assert_equal "failed", invitation.reload.delivery_state
  end

  private

  def with_failing_delivery
    previous = ActionMailer::Base.delivery_method
    ActionMailer::Base.delivery_method = :failing_test
    yield
  ensure
    ActionMailer::Base.delivery_method = previous
  end
end
