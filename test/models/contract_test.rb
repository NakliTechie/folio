# frozen_string_literal: true

require "test_helper"

class ContractTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "contract-model@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Contract Model"
    )
    @customer = Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        party_number: "C-CONTRACT", name: "Contract Customer", country_code: "IN",
        state_code: "27"
      },
      roles: [ "customer" ],
      actor: @org.user
    )
  end

  test "a sell-side draft allocates a scoped number and appends its domain event atomically" do
    contract = create_contract

    assert_equal "CTR/26-27/00001", contract.contract_number
    assert_equal "draft", contract.status
    assert_equal Date.new(2027, 2, 28), contract.notice_deadline_date
    assert_equal 12_000_000, contract.total_contract_value_minor
    assert_equal "contract.drafted", contract.created_domain_event.action
    assert_equal contract.contract_number, contract.created_domain_event.ref
    assert DomainEvent.verify_chain(@org.tenant.id)[:ok]
  end

  test "the governed lifecycle is draft to signed to active to closed" do
    contract = create_contract

    Contracts::Transition.call(
      contract: contract, to: "signed", actor: @org.user, occurred_on: Date.new(2026, 4, 1)
    )
    assert_equal "signed", contract.reload.status
    assert_equal "signed", contract.signature_status
    assert_equal Date.new(2026, 4, 1), contract.execution_date

    Contracts::Transition.call(
      contract: contract, to: "active", actor: @org.user, occurred_on: Date.new(2026, 4, 2)
    )
    assert_equal "active", contract.reload.status

    Contracts::Transition.call(
      contract: contract, to: "closed", actor: @org.user, occurred_on: Date.new(2027, 3, 31)
    )
    assert_equal "closed", contract.reload.status
    assert_equal Date.new(2027, 3, 31), contract.closed_on
    assert_equal %w[contract.drafted contract.signed contract.activated contract.closed],
      DomainEvent.for_tenant(@org.tenant.id).where(ref: contract.contract_number).in_order.pluck(:action)
    assert DomainEvent.verify_chain(@org.tenant.id)[:ok]
  end

  test "invalid lifecycle skips and post-signature edits are rejected" do
    contract = create_contract

    error = assert_raises(Contracts::InvalidTransition) do
      Contracts::Transition.call(
        contract: contract, to: "active", actor: @org.user, occurred_on: Date.new(2026, 4, 1)
      )
    end
    assert_match(/cannot move from draft to active/, error.message)
    assert_equal "draft", contract.reload.status

    Contracts::Transition.call(
      contract: contract, to: "signed", actor: @org.user, occurred_on: Date.new(2026, 4, 1)
    )
    assert_raises(Contracts::InvalidContract) do
      Contracts::Update.call(contract: contract, attributes: { title: "Silent rewrite" }, actor: @org.user)
    end
    assert_equal "Managed services", contract.reload.title
  end

  test "an invalid draft rolls back both the lifecycle event and number allocation" do
    vendor = Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: { party_number: "V-ONLY", name: "Vendor only", country_code: "IN", state_code: "27" },
      roles: [ "vendor" ], actor: @org.user
    )

    assert_no_difference [ "Contract.count", "DomainEvent.count" ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        Contracts::Create.call(
          tenant: @org.tenant, party_id: vendor.id, attributes: contract_attributes, actor: @org.user
        )
      end
    end
    assert_equal "CTR/26-27/00001", create_contract.contract_number
  end

  test "India compliance flags distinguish stamping registration and signature evidence" do
    contract = create_contract(
      stamp_status: "stamped", stamp_date: Date.new(2026, 4, 3),
      execution_date: Date.new(2026, 4, 1), signature_status: "partially_signed",
      registration_required: true, registration_status: "overdue"
    )

    assert_equal [
      "Stamp date follows execution date", "Signature incomplete", "Registration overdue"
    ], contract.compliance_flags
  end

  private

  def create_contract(overrides = {})
    Contracts::Create.call(
      tenant: @org.tenant, party_id: @customer.id,
      attributes: contract_attributes.merge(overrides), actor: @org.user
    )
  end

  def contract_attributes
    {
      title: "Managed services", contract_type: "service_agreement",
      effective_date: Date.new(2026, 4, 1), end_date: Date.new(2027, 3, 31),
      enforceable_period_end: Date.new(2027, 3, 31), term_type: "auto_renew",
      auto_renew: true, renewal_notice_days: 31,
      currency: "INR", total_contract_value_minor: 12_000_000,
      jurisdiction: "IN", stamp_status: "pending", signature_status: "unsigned",
      registration_required: false, registration_status: "not_required",
      gst_treatment: "domestic_b2b", place_of_supply_state_code: "27"
    }
  end
end
