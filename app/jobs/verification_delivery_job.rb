# frozen_string_literal: true

class VerificationDeliveryJob < ApplicationJob
  def perform(user_id)
    user = User.find(user_id)
    return if user.verified?

    claimed = user.with_lock do
      next false if user.verified? || user.verification_delivery_state == "sent"
      active = %w[queued sending].include?(user.verification_delivery_state)
      stale = user.verification_delivery_attempted_at.blank? ||
        user.verification_delivery_attempted_at <= User::DELIVERY_LEASE.ago
      next false unless user.verification_delivery_state == "queued" || (active && stale)

      user.update!(verification_delivery_state: "sending", verification_delivery_attempted_at: Time.current)
      true
    end
    return unless claimed

    RegistrationsMailer.verify(user).deliver_now
    user.update!(verification_delivery_state: "sent", verification_delivery_attempted_at: Time.current)
  rescue StandardError
    user&.update!(verification_delivery_state: "failed", verification_delivery_attempted_at: Time.current)
    raise
  end
end
