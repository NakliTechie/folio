# frozen_string_literal: true

require "test_helper"

class ReadinessTest < ActionDispatch::IntegrationTest
  test "readiness is public and reports a live primary database without leaking connection details" do
    get readiness_path

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal "ok", payload.fetch("status")
    assert_equal [ "primary" ], payload.fetch("checks")
    assert_equal [], payload.fetch("unavailable")
    refute_match(/password|postgresql:/i, response.body)
  end
end
