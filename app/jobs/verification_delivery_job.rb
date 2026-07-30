# frozen_string_literal: true

class VerificationDeliveryJob < ApplicationJob
  def perform(user_id)
    user = User.find(user_id)
    return if user.verified?

    user.update!(verification_delivery_state: "sending", verification_delivery_attempted_at: Time.current)
    RegistrationsMailer.verify(user).deliver_now
    user.update!(verification_delivery_state: "sent", verification_delivery_attempted_at: Time.current)
  rescue StandardError
    user&.update!(verification_delivery_state: "failed", verification_delivery_attempted_at: Time.current)
    raise
  end
end
