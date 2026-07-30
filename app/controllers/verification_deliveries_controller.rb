# frozen_string_literal: true

class VerificationDeliveriesController < BrowserController
  def create
    if Current.user.verified?
      redirect_to root_path(tenant_route_options), notice: "Your email is already verified."
    else
      Current.user.queue_verification_delivery!
      redirect_to root_path(tenant_route_options), notice: "Verification email queued."
    end
  end
end
