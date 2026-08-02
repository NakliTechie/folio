# frozen_string_literal: true

# Shared base for the authenticated, server-rendered product surface.
class BrowserController < ApplicationController
  include TenantScoped
  include MfaGate

  helper_method :current_tenant, :current_role_assignment, :permitted?, :tenant_route_options,
    :business_date

  private

  def current_tenant
    Current.tenant
  end

  def current_role_assignment
    @current_role_assignment ||= Authorization.role_for(
      user: Current.user,
      tenant_id: Current.tenant.id
    )
  end

  def permitted?(capability)
    Authorization.permits?(
      user: Current.user,
      tenant_id: Current.tenant.id,
      capability: capability
    )
  end

  def require_capability!(capability)
    return if permitted?(capability)

    redirect_to root_path(tenant_route_options), alert: "You do not have permission to do that."
  end

  def tenant_route_options
    { tenant_id: Current.tenant.id }
  end

  def business_date
    Current.tenant.business_date
  end

  def render_no_tenant
    redirect_to new_registration_path, alert: "Create or join a company to continue."
  end
end
