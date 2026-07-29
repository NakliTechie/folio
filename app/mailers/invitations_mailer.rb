# frozen_string_literal: true

class InvitationsMailer < ApplicationMailer
  def invite(invitation)
    @invitation = invitation
    @token = invitation.generate_token_for(:invite)
    mail to: invitation.email, subject: "You've been invited to Folio"
  end
end
