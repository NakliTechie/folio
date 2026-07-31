# frozen_string_literal: true

# The tenancy isolation gate. Resolves Current.tenant STRICTLY through the authenticated
# user's memberships AND a tenant-wide role, so a user can never reach a tenant they are not
# authorized to operate — the load-bearing v1 multi-tenant invariant. Office-specific role
# selection is reserved in the schema but is not an active product boundary until every read
# and write can carry selected-office context. The tenant selector (a param or the X-Tenant
# header) only picks among authorized tenants; a miss resolves to nil → forbidden.
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

    tenant_wide_roles = UserOfficeRole.where(user_id: user.id, office_id: nil).select(:tenant_id)
    authorized_tenants = user.tenants.where(id: tenant_wide_roles)
    requested = params[:tenant_id].presence || request.headers["X-Tenant"].presence
    if requested
      authorized_tenants.find_by(id: requested)
    else
      authorized_tenants.first
    end
  end

  def render_no_tenant
    render json: { error: "no accessible tenant" }, status: :forbidden
  end
end
