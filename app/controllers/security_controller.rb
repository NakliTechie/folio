# frozen_string_literal: true

class SecurityController < BrowserController
  def show
    @sessions = Current.user.sessions.active_at.order(created_at: :desc)
  end

  def mfa_setup
    return redirect_to security_path(tenant_route_options), notice: "Multi-factor authentication is already enabled." if Current.user.mfa_enabled?

    remember_mfa_return_path
    @mfa_secret = pending_mfa_secret
    @provisioning_uri = Mfa::Totp.provisioning_uri(
      secret: @mfa_secret, email: Current.user.email_address
    )
  end

  def enable_mfa
    secret = Mfa::Cipher.decrypt(session[:pending_mfa_secret].to_s)
    unless Current.user.authenticate(params[:password]) && Mfa::Totp.valid?(secret, params[:code])
      return redirect_to mfa_setup_security_path(tenant_route_options),
        alert: "Password or authenticator code was invalid. Check the current setup and try again."
    end

    recovery_codes = Mfa::RecoveryCodes.generate
    Current.user.enable_mfa!(secret: secret, recovery_codes: recovery_codes)
    session.delete(:pending_mfa_secret)
    session[:pending_mfa_recovery_codes] = Mfa::Cipher.encrypt(recovery_codes.join("\n"))
    Current.session.update!(mfa_verified_at: Time.current)
    Current.user.sessions.where.not(id: Current.session.id).destroy_all
    redirect_to mfa_recovery_codes_security_path(tenant_route_options), status: :see_other
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    redirect_to security_path(tenant_route_options), alert: "MFA setup expired. Start again."
  end

  def mfa_recovery_codes
    encrypted_codes = session.delete(:pending_mfa_recovery_codes)
    return redirect_to security_path(tenant_route_options), notice: "Multi-factor authentication is enabled." if encrypted_codes.blank?

    @recovery_codes = Mfa::Cipher.decrypt(encrypted_codes).split("\n")
    @continue_path = session.delete(:return_after_mfa_enrollment).presence || security_path(tenant_route_options)
    render :mfa_enabled
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    redirect_to security_path(tenant_route_options), alert: "Recovery-code display expired. Your MFA remains enabled."
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

  private

  def pending_mfa_secret
    encrypted_secret = session[:pending_mfa_secret]
    return Mfa::Cipher.decrypt(encrypted_secret) if encrypted_secret.present?

    Mfa::Totp.generate_secret.tap do |secret|
      session[:pending_mfa_secret] = Mfa::Cipher.encrypt(secret)
    end
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    session.delete(:pending_mfa_secret)
    retry
  end

  def remember_mfa_return_path
    candidate = params[:return_to].to_s
    return unless candidate.start_with?("/") && !candidate.start_with?("//")

    uri = URI.parse(candidate)
    session[:return_after_mfa_enrollment] = candidate if uri.host.nil? && uri.scheme.nil?
  rescue URI::InvalidURIError
    nil
  end
end
