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
      password: "correct-horse-battery",
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
      password: "correct-horse-battery",
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
      email: "delivery-owner@x.com", password: "correct-horse-battery", org_name: "Delivery Books"
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

  test "verification queue suppresses duplicate deliveries and permits a cooled-down retry" do
    user = User.create!(email_address: "verification-queue@x.com", password: "correct-horse-battery")

    assert_enqueued_jobs 1, only: VerificationDeliveryJob do
      assert user.queue_verification_delivery!
      refute user.queue_verification_delivery!
    end

    user.update!(verification_delivery_state: "failed", verification_delivery_attempted_at: 2.minutes.ago)
    assert_enqueued_jobs 1, only: VerificationDeliveryJob do
      assert user.queue_verification_delivery!
    end
  end

  test "invitation queue suppresses duplicate deliveries and stops after acceptance" do
    org = Onboarding::SignUp.call(
      email: "invitation-queue-owner@x.com", password: "correct-horse-battery", org_name: "Queue Books"
    )
    invitation = Onboarding::Invite.create!(
      tenant: org.tenant,
      email: "invitation-queue@x.com",
      role_code: "viewer",
      invited_by: org.user
    )

    assert_enqueued_jobs 1, only: InvitationDeliveryJob do
      assert invitation.queue_delivery!
      refute invitation.queue_delivery!
    end

    invitation.update!(delivery_state: "failed", delivery_attempted_at: 2.minutes.ago)
    assert_enqueued_jobs 1, only: InvitationDeliveryJob do
      assert invitation.queue_delivery!
    end

    invitation.update!(accepted_at: Time.current, delivery_state: "sent")
    assert_no_enqueued_jobs only: InvitationDeliveryJob do
      refute invitation.queue_delivery!
    end
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
