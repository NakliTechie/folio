# frozen_string_literal: true

class SecurityController < BrowserController
  def show
    @sessions = Current.user.sessions.active_at.order(created_at: :desc)
  end

  def mfa_setup
    return redirect_to security_path(tenant_route_options), notice: "Multi-factor authentication is already enabled." if Current.user.mfa_enabled?

    @mfa_secret = Mfa::Totp.generate_secret
    session[:pending_mfa_secret] = Mfa::Cipher.encrypt(@mfa_secret)
    @provisioning_uri = Mfa::Totp.provisioning_uri(
      secret: @mfa_secret, email: Current.user.email_address
    )
    render :mfa_setup
  end

  def enable_mfa
    secret = Mfa::Cipher.decrypt(session[:pending_mfa_secret].to_s)
    unless Current.user.authenticate(params[:password]) && Mfa::Totp.valid?(secret, params[:code])
      return redirect_to security_path(tenant_route_options),
        alert: "Password or authenticator code was invalid. Start setup again."
    end

    @recovery_codes = Mfa::RecoveryCodes.generate
    Current.user.enable_mfa!(secret: secret, recovery_codes: @recovery_codes)
    session.delete(:pending_mfa_secret)
    Current.session.update!(mfa_verified_at: Time.current)
    Current.user.sessions.where.not(id: Current.session.id).destroy_all
    render :mfa_enabled
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    redirect_to security_path(tenant_route_options), alert: "MFA setup expired. Start again."
  end

  def disable_mfa
    valid = Current.user.authenticate(params[:password]) &&
      Mfa::Verify.call(Current.user, params[:code])
    unless valid
      return redirect_to security_path(tenant_route_options),
        alert: "Password or authenticator code was invalid."
    end

    Current.user.disable_mfa!
    Current.session.update!(mfa_verified_at: nil)
    Current.user.sessions.where.not(id: Current.session.id).destroy_all
    redirect_to security_path(tenant_route_options), notice: "Multi-factor authentication disabled."
  end
end
