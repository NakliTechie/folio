# frozen_string_literal: true

# Production launch policy: authenticated users may inspect their books before verification, but
# cannot mutate tenant state. Reading first keeps recovery possible; gating writes prevents an
# unreachable or mistyped mailbox from becoming an operating identity.
module EmailVerificationGate
  extend ActiveSupport::Concern

  included do
    before_action :require_verified_email_for_write!
  end

  class_methods do
    def allow_unverified_write_access(**options)
      skip_before_action :require_verified_email_for_write!, **options
    end
  end

  private

  def require_verified_email_for_write!
    return unless Rails.application.config.x.email_verification_required
    return if request.get? || request.head? || request.options?

    user = Current.session&.user
    return unless user
    return if user.verified?

    deny_unverified_email_write
  end

  def deny_unverified_email_write
    redirect_to root_path, alert: "Verify your email before changing the company books."
  end
end
