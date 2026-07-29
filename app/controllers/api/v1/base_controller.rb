# frozen_string_literal: true

module Api
  module V1
    # The authenticated, tenant-scoped JSON API base. Inherits ActionController::Base (NOT
    # ApplicationController) to avoid allow_browser blocking non-browser API clients. Auth uses
    # the same signed session cookie, but an unauthenticated request gets a 401 JSON, not an
    # HTML redirect.
    class BaseController < ActionController::Base
      include Authentication
      include TenantScoped

      private

      def request_authentication
        render json: { error: "authentication required" }, status: :unauthorized
      end
    end
  end
end
