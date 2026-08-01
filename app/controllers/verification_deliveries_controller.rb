# frozen_string_literal: true

class VerificationDeliveriesController < BrowserController
  allow_unverified_write_access only: :create
  def create
    if Current.user.verified?
      redirect_to root_path(tenant_route_options), notice: "Your email is already verified."
    elsif Current.user.queue_verification_delivery!
      redirect_to root_path(tenant_route_options), notice: "Verification email queued."
    else
      redirect_to root_path(tenant_route_options),
        notice: "Verification is already queued or was sent recently. Try again in a minute."
    end
  end
end
