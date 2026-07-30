# frozen_string_literal: true

class InvitationDeliveryJob < ApplicationJob
  def perform(invitation_id)
    invitation = Invitation.find(invitation_id)
    return unless invitation.pending?

    invitation.update!(delivery_state: "sending", delivery_attempted_at: Time.current)
    InvitationsMailer.invite(invitation).deliver_now
    invitation.update!(delivery_state: "sent", delivery_attempted_at: Time.current)
  rescue StandardError
    invitation&.update!(delivery_state: "failed", delivery_attempted_at: Time.current)
    raise
  end
end
