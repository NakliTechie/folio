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
end
