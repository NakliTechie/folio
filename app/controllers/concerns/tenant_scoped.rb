# frozen_string_literal: true

# The tenancy isolation gate. Resolves Current.tenant STRICTLY through the authenticated
# user's memberships, so a user can never reach a tenant they are not a member of — the
# load-bearing multi-tenant invariant. The tenant selector (a param or the X-Tenant header)
# is only ever used to PICK AMONG the user's own tenants; an unknown/foreign id resolves to
# nil → forbidden, never to the requested tenant.
module TenantScoped
  extend ActiveSupport::Concern

  included do
    before_action :require_tenant
  end

  private

  def require_tenant
    Current.tenant = resolve_tenant
    render_no_tenant unless Current.tenant
  end

  def resolve_tenant
    user = Current.session&.user
    return nil unless user

    requested = params[:tenant_id].presence || request.headers["X-Tenant"].presence
    if requested
      user.tenants.find_by(id: requested) # membership-scoped: foreign ids resolve to nil
    else
      user.tenants.first
    end
  end

  def render_no_tenant
    render json: { error: "no accessible tenant" }, status: :forbidden
  end
end
