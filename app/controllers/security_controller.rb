# frozen_string_literal: true

class SecurityController < BrowserController
  def show
    @sessions = Current.user.sessions.active_at.order(created_at: :desc)
  end
end
