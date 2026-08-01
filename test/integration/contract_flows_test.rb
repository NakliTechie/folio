# frozen_string_literal: true

require "test_helper"

class ContractFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "contract-owner@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Contract Browser"
    )
    @customer = Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        party_number: "C-001", name: "Acme Customer", country_code: "IN", state_code: "27"
      },
      roles: [ "customer" ], actor: @org.user
    )
    sign_in_as(@org.user)
  end

  test "owner creates and advances a contract through the browser lifecycle" do
    get new_contract_path
    assert_response :success
    assert_select "h1", "Create a contract"
    assert_select "body", text: /does not calculate authoritative duty/

    assert_difference "Contract.count", 1 do
      post contracts_path, params: { contract: browser_params }
    end
    contract = Contract.order(:id).last
    assert_redirected_to contract_path(contract, tenant_id: @org.tenant.id)
    assert_equal 12_000_000, contract.total_contract_value_minor

    follow_redirect!
    assert_select "h1", "CTR/26-27/00001"
    assert_select "[role=status]", text: /Stamp evidence pending.*Signature incomplete/m
    assert_select "form[action^='/contracts/#{contract.id}/sign']" do
      assert_select "input[type=submit][value='Mark signed']"
    end

    post sign_contract_path(contract), params: { execution_date: "2026-04-01" }
    assert_redirected_to contract_path(contract, tenant_id: @org.tenant.id)
    assert_equal "signed", contract.reload.status

    post activate_contract_path(contract), params: { effective_date: "2026-04-01" }
    assert_equal "active", contract.reload.status
    post close_contract_path(contract), params: { closed_on: "2027-03-31" }
    assert_equal "closed", contract.reload.status

    get contract_path(contract)
    assert_response :success
    assert_select "table", text: /contract\.drafted.*contract\.signed.*contract\.activated.*contract\.closed/im
    assert DomainEvent.verify_chain(@org.tenant.id)[:ok]
  end

  test "viewer can read contracts but cannot reach creation or lifecycle mutations" do
    contract = create_contract
    viewer = invite_user("contract-viewer@folio.invalid", "viewer")
    sign_out
    sign_in_as(viewer)

    get contracts_path
    assert_response :success
    get contract_path(contract)
    assert_response :success
    assert_select "a", text: "Edit draft", count: 0
    assert_select "form[action^='/contracts/#{contract.id}/sign']", count: 0

    get new_contract_path
    assert_redirected_to root_path(tenant_id: @org.tenant.id)
    assert_no_difference "DomainEvent.count" do
      post sign_contract_path(contract), params: { execution_date: "2026-04-01" }
    end
    assert_redirected_to root_path(tenant_id: @org.tenant.id)
    assert_equal "draft", contract.reload.status
  end

  test "owner identifies obligations allocates schedules and simulates recognition in the workspace" do
    contract = create_contract

    assert_difference "ContractPerformanceObligation.count", 1 do
      post create_performance_obligation_contract_path(contract), params: {
        performance_obligation: {
          description: "Annual managed service", satisfaction: "over_time",
          over_time_criterion: "Customer simultaneously receives the service",
          progress_measure: "time_elapsed", standalone_selling_price: "120000.00",
          ssp_method: "observable", service_start_date: "2026-04-01",
          service_end_date: "2027-03-31", distinct: "1", revenue_account_code: "4000"
        }
      }
    end
    assert_redirected_to contract_path(contract, tenant_id: @org.tenant.id)

    post sign_contract_path(contract), params: { execution_date: "2026-03-31" }
    post activate_contract_path(contract), params: { effective_date: "2026-04-01" }
    assert_difference "ContractAllocationRun.count", 1 do
      post allocate_transaction_price_contract_path(contract), params: { effective_date: "2026-04-01" }
    end
    assert_difference "ContractSchedule.count", 1 do
      post generate_revenue_schedules_contract_path(contract)
    end

    get contract_path(contract)
    assert_response :success
    assert_select "h2", text: "Performance obligations"
    assert_select "table", text: /Annual managed service/
    assert_select "table", text: /Straight line.*Current/m

    assert_no_difference "LedgerEvent.count" do
      assert_difference "ContractPostingRun.count", 1 do
        post run_revenue_recognition_contract_path(contract), params: {
          mode: "simulate", posting_date: "2026-04-30", idempotency_key: "browser-sim-#{contract.id}"
        }
      end
    end
    assert_equal "simulated", contract.contract_posting_runs.last.status
    assert_equal 1_000_000, contract.contract_posting_runs.last.result.fetch("contract_asset_minor")
  end

  test "contract reads are tenant opaque" do
    contract = create_contract
    other = Onboarding::SignUp.call(
      email: "contract-other@folio.invalid", password: "correct-horse-battery", org_name: "Other Contracts"
    )
    sign_out
    sign_in_as(other.user)

    get contract_path(contract)
    assert_response :not_found
  end

  private

  def create_contract
    Contracts::Create.call(
      tenant: @org.tenant, party_id: @customer.id,
      attributes: {
        title: "Managed services", contract_type: "service_agreement",
        effective_date: Date.new(2026, 4, 1), end_date: Date.new(2027, 3, 31),
        term_type: "fixed", currency: "INR", total_contract_value_minor: 12_000_000,
        jurisdiction: "IN", stamp_status: "pending", signature_status: "unsigned",
        registration_required: false, registration_status: "not_required",
        gst_treatment: "domestic_b2b", place_of_supply_state_code: "27"
      },
      actor: @org.user
    )
  end

  def browser_params
    {
      party_id: @customer.id, title: "Managed services", contract_type: "service_agreement",
      effective_date: "2026-04-01", end_date: "2027-03-31",
      enforceable_period_end: "2027-03-31", term_type: "auto_renew", auto_renew: "1",
      renewal_notice_days: "31", total_contract_value: "120000.00", jurisdiction: "IN",
      stamp_status: "pending", signature_status: "unsigned", registration_required: "0",
      registration_status: "not_required", gst_treatment: "domestic_b2b",
      place_of_supply_state_code: "27"
    }
  end

  def invite_user(email, role_code)
    invitation = Onboarding::Invite.create!(
      tenant: @org.tenant, email: email, role_code: role_code, invited_by: @org.user
    )
    Onboarding::Invite.accept!(
      token: invitation.generate_token_for(:invite), password: "correct-horse-battery"
    )
  end
end
