# frozen_string_literal: true

class InvitationDeliveryJob < ApplicationJob
  def perform(invitation_id)
    invitation = Invitation.find(invitation_id)
    return unless invitation.pending?

    claimed = invitation.with_lock do
      next false unless invitation.pending?
      active = %w[queued sending].include?(invitation.delivery_state)
      stale = invitation.delivery_attempted_at.blank? ||
        invitation.delivery_attempted_at <= Invitation::DELIVERY_LEASE.ago
      next false unless invitation.delivery_state == "queued" || (active && stale)

      invitation.update!(delivery_state: "sending", delivery_attempted_at: Time.current)
      true
    end
    return unless claimed

    InvitationsMailer.invite(invitation).deliver_now
    invitation.update!(delivery_state: "sent", delivery_attempted_at: Time.current)
  rescue StandardError
    invitation&.update!(delivery_state: "failed", delivery_attempted_at: Time.current)
    raise
  end
end
