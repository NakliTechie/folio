# frozen_string_literal: true

require "digest"

# Self-serve signup: create the org + owner + seeded books, log in, and send a verification email.
# Production permits reads before verification but gates every authenticated write.
class RegistrationsController < ApplicationController
  allow_unauthenticated_access only: %i[new create verify confirm_verification]
  allow_unverified_write_access only: %i[create confirm_verification]
  rate_limit to: 5, within: 1.hour, only: :create,
    with: -> { redirect_to new_registration_path, alert: "Too many signup attempts. Please try again later." }
  rate_limit to: 10, within: 10.minutes, only: :confirm_verification,
    by: -> { "#{request.remote_ip}:#{Digest::SHA256.hexdigest(params[:token].to_s)}" },
    with: -> { redirect_to verify_email_path(token: params[:token]), alert: "Too many verification attempts. Try again later." }

  def new
  end

  def create
    result = Onboarding::SignUp.call(
      email: params[:email_address],
      password: params[:password],
      org_name: params[:org_name],
      jurisdiction_profile: params[:jurisdiction_profile],
      functional_currency: params[:functional_currency],
      fiscal_year_variant: params[:fiscal_year_variant],
      time_zone: params[:time_zone]
    )
    start_new_session_for result.user
    session.delete(:return_to_after_authenticating)
    result.user.queue_verification_delivery!
    redirect_to root_path, notice: "Welcome to Folio — #{result.tenant.name} is ready."
  rescue ActiveRecord::RecordInvalid, Onboarding::AccountingProfile::InvalidChoice => e
    flash.now[:alert] = if e.respond_to?(:record)
      e.record.errors.full_messages.to_sentence.presence || e.message
    else
      e.message
    end
    render :new, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotUnique
    flash.now[:alert] = "That email or company was registered moments ago. Sign in or choose another."
    render :new, status: :unprocessable_entity
  end

  # GET is deliberately read-only: enterprise mail scanners frequently open links. The user must
  # confirm with a CSRF-protected POST before the trust marker changes.
  def verify
    @user = User.find_by_token_for(:email_verification, params[:token])
    @token = params[:token]
    redirect_to root_path, alert: "That verification link is invalid or has expired." unless @user
  end

  def confirm_verification
    if (user = User.find_by_token_for(:email_verification, params[:token]))
      user.verify! unless user.verified?
      redirect_to root_path, notice: "Email verified."
    else
      redirect_to root_path, alert: "That verification link is invalid or has expired."
    end
  end
end
