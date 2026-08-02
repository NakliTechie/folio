require "digest"

class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  allow_unverified_write_access only: :destroy
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: "Try again later." }
  rate_limit to: 5, within: 15.minutes, only: :create, name: "account",
    by: -> { Digest::SHA256.hexdigest(params[:email_address].to_s.strip.downcase) },
    with: -> { redirect_to new_session_path, alert: "Try again later." }

  def new
  end

  def create
    if user = User.authenticate_by(params.permit(:email_address, :password))
      if user.mfa_enabled?
        session[:pending_mfa_user_id] = user.id
        redirect_to new_mfa_session_path
      else
        start_new_session_for user
        redirect_to after_authentication_url
      end
    else
      redirect_to new_session_path, alert: "Try another email address or password."
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end
end
