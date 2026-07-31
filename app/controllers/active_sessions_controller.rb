# frozen_string_literal: true

class ActiveSessionsController < BrowserController
  def destroy
    target = Current.user.sessions.find(params[:id])
    if target.id == Current.session.id
      terminate_session
      redirect_to new_session_path, status: :see_other, notice: "This device has been signed out."
    else
      target.destroy!
      redirect_to security_path(tenant_route_options), status: :see_other,
        notice: "The selected session has been revoked."
    end
  end
end
