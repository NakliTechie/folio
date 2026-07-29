# frozen_string_literal: true

class RegistrationsMailer < ApplicationMailer
  def verify(user)
    @user = user
    @token = user.generate_token_for(:email_verification)
    mail to: user.email_address, subject: "Verify your email for Folio"
  end
end
