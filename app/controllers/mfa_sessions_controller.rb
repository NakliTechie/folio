# frozen_string_literal: true

require "digest"

class MfaSessionsController < ApplicationController
  allow_unauthenticated_access
  allow_unverified_write_access
  rate_limit to: 10, within: 5.minutes, only: :create, name: "ip",
    with: -> { redirect_to new_mfa_session_path, alert: "Try again later." }
  rate_limit to: 5, within: 15.minutes, only: :create, name: "account",
    by: -> { Digest::SHA256.hexdigest(session[:pending_mfa_user_id].to_s) },
    with: -> { redirect_to new_mfa_session_path, alert: "Try again later." }

  def new
    redirect_to new_session_path unless pending_user
  end

  def create
    user = pending_user
    return redirect_to(new_session_path, alert: "Sign in again.") unless user

    if Mfa::Verify.call(user, params[:code])
      session.delete(:pending_mfa_user_id)
      start_new_session_for(user, mfa_verified: true)
      redirect_to after_authentication_url
    else
      redirect_to new_mfa_session_path, alert: "That authenticator or recovery code is invalid."
    end
  end

  private

  def pending_user
    User.find_by(id: session[:pending_mfa_user_id])
  end
end
