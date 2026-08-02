# frozen_string_literal: true

module MfaGate
  extend ActiveSupport::Concern

  included do
    before_action :require_mfa_enrollment
  end

  private

  def require_mfa_enrollment
    return unless Rails.application.config.x.mfa_required
    return unless Current.user && !Current.user.mfa_enabled?
    return unless request.post? || request.patch? || request.put? || request.delete?
    return if controller_name == "security" && action_name.in?(%w[mfa_setup enable_mfa])

    deny_mfa_enrollment
  end

  def deny_mfa_enrollment
    redirect_to security_path(tenant_id: Current.tenant&.id),
      alert: "Set up multi-factor authentication before changing company data."
  end
end
