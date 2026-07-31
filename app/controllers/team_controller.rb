# frozen_string_literal: true

class TeamController < BrowserController
  before_action -> { require_capability!("users.manage") }

  def show
    @memberships = Membership.where(tenant_id: Current.tenant.id).includes(:user).order(:created_at)
    @role_by_user_id = UserOfficeRole.where(
      tenant_id: Current.tenant.id,
      user_id: @memberships.map(&:user_id),
      office_id: nil
    ).includes(:role_template).index_by(&:user_id)
    @invitations = Invitation.where(tenant_id: Current.tenant.id).order(created_at: :desc)
  end

  def update_role
    member = Membership.where(tenant_id: Current.tenant.id).includes(:user).find_by!(user_id: params[:user_id])
    assignment = TeamRoles::Change.call!(
      tenant: Current.tenant,
      user: member.user,
      role_code: params[:role_code],
      actor: Current.user
    )
    redirect_to team_path(tenant_route_options),
      notice: "#{member.user.email_address} is now #{assignment.role_template.name}."
  rescue TeamRoles::LastOwner, TeamRoles::InvalidRole, ActiveRecord::RecordInvalid,
    ActiveRecord::InvalidForeignKey => e
    redirect_to team_path(tenant_route_options), alert: e.message
  end
end
