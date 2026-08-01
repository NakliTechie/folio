# frozen_string_literal: true

# Dependency health for the trusted load balancer. The response identifies only failed service
# classes; exception details stay in structured server logs.
class ReadinessController < ActionController::Base
  def show
    result = Folio::Readiness.call
    render json: result, status: result.fetch(:status) == "ok" ? :ok : :service_unavailable
  end
end
