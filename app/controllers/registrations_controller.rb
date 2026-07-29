# frozen_string_literal: true

# Self-serve signup: create the org + owner + seeded books, log in, and send a verification
# email (soft — it marks trust; nothing is gated on it yet).
class RegistrationsController < ApplicationController
  allow_unauthenticated_access only: %i[new create verify]

  def new
  end

  def create
    result = Onboarding::SignUp.call(
      email: params[:email_address], password: params[:password], org_name: params[:org_name]
    )
    start_new_session_for result.user
    RegistrationsMailer.verify(result.user).deliver_later
    redirect_to root_path, notice: "Welcome to Folio — #{result.tenant.name} is ready."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to new_registration_path, alert: e.record.errors.full_messages.to_sentence.presence || e.message
  end

  # GET /verify/:token — from the verification email.
  def verify
    if (user = User.find_by_token_for(:email_verification, params[:token]))
      user.verify!
      redirect_to root_path, notice: "Email verified."
    else
      redirect_to root_path, alert: "That verification link is invalid or has expired."
    end
  end
end
