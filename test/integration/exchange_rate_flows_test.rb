# frozen_string_literal: true

require "test_helper"

class ExchangeRateFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "fx-owner@folio.invalid",
      password: "correct-horse-battery",
      org_name: "FX Browser"
    )
    sign_in_as(@org.user)
  end

  test "owner records rates and simulates a closing revaluation from the browser" do
    get exchange_rates_path
    assert_response :success
    assert_select "h1", "Exchange rates"

    assert_difference "ExchangeRate.count", 1 do
      post exchange_rates_path, params: {
        exchange_rate: {
          from_currency: "USD", to_currency: "INR", effective_on: "2026-08-01",
          rate: "83.25", rate_type: "spot", source: "Approved bank feed"
        }
      }
    end
    assert_redirected_to exchange_rates_path(tenant_id: @org.tenant.id)
    rate = ExchangeRate.order(:id).last
    assert EventSigning.verify(LedgerEvent.for_tenant(@org.tenant.id).in_order.last)

    assert_difference "ExchangeRate.count", 1 do
      post exchange_rates_path, params: {
        exchange_rate: {
          from_currency: "USD", to_currency: "INR", effective_on: "2026-08-31",
          rate: "84.00", rate_type: "closing", source: "Approved bank feed"
        }
      }
    end
    assert_equal "USD", rate.from_currency

    assert_difference "ExchangeRevaluationRun.count", 1 do
      post run_revaluation_exchange_rates_path, params: {
        revaluation_date: "2026-08-31", mode: "simulate", idempotency_key: "browser-fx-sim"
      }
    end
    assert_redirected_to exchange_rates_path(tenant_id: @org.tenant.id)
    assert_equal "simulated", ExchangeRevaluationRun.order(:id).last.status
  end

  test "viewer can inspect rate evidence but cannot create rates or run revaluation" do
    viewer = invite_user("fx-viewer@folio.invalid", "viewer")
    sign_out
    sign_in_as(viewer)

    get exchange_rates_path
    assert_response :success
    assert_select "form[action='#{exchange_rates_path}']", count: 0

    assert_no_difference "ExchangeRate.count" do
      post exchange_rates_path, params: {
        exchange_rate: {
          from_currency: "USD", to_currency: "INR", effective_on: "2026-08-01",
          rate: "83", rate_type: "spot", source: "Unapproved"
        }
      }
    end
    assert_redirected_to root_path(tenant_id: @org.tenant.id)
    assert_no_difference "ExchangeRevaluationRun.count" do
      post run_revaluation_exchange_rates_path, params: {
        revaluation_date: "2026-08-31", mode: "post", idempotency_key: "denied"
      }
    end
    assert_redirected_to root_path(tenant_id: @org.tenant.id)
  end

  private

  def invite_user(email, role_code)
    invitation = Onboarding::Invite.create!(
      tenant: @org.tenant, email: email, role_code: role_code, invited_by: @org.user
    )
    Onboarding::Invite.accept!(
      token: invitation.generate_token_for(:invite), password: "correct-horse-battery"
    )
  end
end
