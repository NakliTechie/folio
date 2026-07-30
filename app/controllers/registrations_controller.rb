# frozen_string_literal: true

# Self-serve signup: create the org + owner + seeded books, log in, and send a verification
# email (soft — it marks trust; nothing is gated on it yet).
class RegistrationsController < ApplicationController
  allow_unauthenticated_access only: %i[new create verify]
  rate_limit to: 5, within: 1.hour, only: :create,
    with: -> { redirect_to new_registration_path, alert: "Too many signup attempts. Please try again later." }

  def new
  end

  def create
    result = Onboarding::SignUp.call(
      email: params[:email_address],
      password: params[:password],
      org_name: params[:org_name],
      jurisdiction_profile: params[:jurisdiction_profile],
      functional_currency: params[:functional_currency],
      fiscal_year_variant: params[:fiscal_year_variant]
    )
    start_new_session_for result.user
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
