# frozen_string_literal: true

module Api
  module V1
    # Authenticated, tenant-scoped JSON API base. ActionController::Base (not
    # ApplicationController) so allow_browser never blocks API clients. Auth is the same signed
    # session cookie; writes keep Rails CSRF protection (the Hotwire UI sends the token —
    # same-origin). A bearer-token scheme for external/programmatic clients is a parked follow-up.
    class BaseController < ActionController::Base
      include Authentication
      include TenantScoped
      protect_from_forgery with: :exception

      rescue_from ActiveRecord::RecordNotFound, with: :not_found
      rescue_from ActiveRecord::RecordInvalid do |e|
        render_error(e.record.errors.full_messages.to_sentence, :unprocessable_entity)
      end
      rescue_from Posting::UnbalancedError do |e|
        render_error("entry does not balance: #{e.message}", :unprocessable_entity)
      end
      rescue_from Documents::Post::NotPermitted do |e| render_error(e.message, :forbidden) end
      rescue_from Documents::Post::NotPostable do |e| render_error(e.message, :conflict) end
      # A JSON API stays JSON even on a CSRF failure (Rails' default is a static HTML page).
      rescue_from ActionController::InvalidAuthenticityToken do
        render_error("invalid or missing CSRF token", :unprocessable_entity)
      end

      private

      def request_authentication
        render json: { error: "authentication required" }, status: :unauthorized
      end

      def current_user
        Current.session.user
      end

      # Guard a write action with a capability; halts with 403 if not permitted.
      def require_capability!(capability)
        return true if Authorization.permits?(user: current_user, tenant_id: Current.tenant.id, capability: capability)
        render_error("not permitted (#{capability})", :forbidden)
        false
      end

      def not_found
        render_error("not found", :not_found)
      end

      def render_error(message, status)
        render json: { error: message }, status: status
      end
    end
  end
end
