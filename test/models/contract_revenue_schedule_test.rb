# frozen_string_literal: true

require "test_helper"

class ContractRevenueScheduleTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "revenue-schedule@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Revenue Schedule"
    )
    @customer = Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        party_number: "C-RR", name: "Revenue Customer", country_code: "IN", state_code: "27"
      },
      roles: [ "customer" ], actor: @org.user
    )
    @contract = Contracts::Create.call(
      tenant: @org.tenant, party_id: @customer.id, actor: @org.user,
      attributes: {
        title: "Implementation and support", contract_type: "service_agreement",
        effective_date: Date.new(2026, 4, 1), end_date: Date.new(2027, 3, 31),
        term_type: "fixed", currency: "INR", total_contract_value_minor: 1_000_001,
        jurisdiction: "IN", stamp_status: "pending", signature_status: "unsigned",
        registration_required: false, registration_status: "not_required",
        gst_treatment: "domestic_b2b", place_of_supply_state_code: "27"
      }
    )
  end

  test "relative SSP allocation is exact deterministic immutable and hash chained" do
    implementation = add_obligation(
      description: "Implementation", satisfaction: "point_in_time",
      standalone_selling_price_minor: 400_000, ssp_method: "observable"
    )
    support = add_obligation(
      description: "Support", satisfaction: "over_time",
      over_time_criterion: "customer simultaneously receives benefits", progress_measure: "time_elapsed",
      standalone_selling_price_minor: 600_000, ssp_method: "observable",
      service_start_date: Date.new(2026, 4, 1), service_end_date: Date.new(2027, 3, 31)
    )

    run = Contracts::AllocateTransactionPrice.call(
      contract: @contract, actor: @org.user, effective_date: Date.new(2026, 4, 1)
    )

    assert_equal 1, run.version
    assert_equal 1_000_001, run.contract_allocation_lines.sum(:allocated_price_minor)
    assert_equal 400_000, run.contract_allocation_lines.find_by!(
      contract_performance_obligation: implementation
    ).allocated_price_minor
    assert_equal 600_001, run.contract_allocation_lines.find_by!(
      contract_performance_obligation: support
    ).allocated_price_minor
    assert_equal "contract.transaction_price_allocated", run.created_domain_event.action
    assert_not run.update(method: "residual")
    assert_includes run.errors.full_messages.to_sentence, "immutable"
    error = assert_raises(ActiveRecord::StatementInvalid) do
      ContractAllocationRun.transaction(requires_new: true) { run.update_column(:method, "residual") }
    end
    assert_match(/contract_allocation_runs is immutable/, error.message)
    assert DomainEvent.verify_chain(@org.tenant.id)[:ok]
  end

  test "straight-line schedules preserve every minor unit and supersede unposted versions" do
    obligation = add_obligation(
      description: "Annual support", satisfaction: "over_time",
      over_time_criterion: "customer simultaneously receives benefits", progress_measure: "time_elapsed",
      standalone_selling_price_minor: 1_000_001, ssp_method: "observable",
      service_start_date: Date.new(2026, 4, 1), service_end_date: Date.new(2027, 3, 31)
    )
    activate_contract
    Contracts::AllocateTransactionPrice.call(
      contract: @contract, actor: @org.user, effective_date: Date.new(2026, 4, 1)
    )

    first = Contracts::GenerateRevenueSchedules.call(contract: @contract, actor: @org.user).sole

    assert_equal "straight_line", first.method
    assert_equal 12, first.contract_schedule_lines.count
    assert_equal 1_000_001, first.contract_schedule_lines.sum(:amount_minor)
    assert_equal 83_334, first.contract_schedule_lines.in_order_of(:sequence, (1..12).to_a).first.amount_minor
    assert_equal Date.new(2026, 4, 30), first.contract_schedule_lines.order(:sequence).first.due_date
    assert_equal Date.new(2027, 3, 31), first.contract_schedule_lines.order(:sequence).last.due_date

    second = Contracts::GenerateRevenueSchedules.call(contract: @contract, actor: @org.user).sole

    assert_equal 2, second.version
    assert_equal "superseded", first.reload.status
    assert_equal [ "superseded" ], first.contract_schedule_lines.distinct.pluck(:status)
    assert_equal "current", second.status
    assert_equal obligation.id, second.contract_performance_obligation_id
  end

  test "milestone schedules require exact allocation and achieved acceptance evidence" do
    obligation = add_obligation(
      description: "Implementation", satisfaction: "point_in_time",
      standalone_selling_price_minor: 1_000_001, ssp_method: "observable",
      service_end_date: Date.new(2026, 6, 30)
    )
    first = add_milestone(obligation, "Configuration accepted", Date.new(2026, 5, 31), 400_000)
    second = add_milestone(obligation, "Go-live accepted", Date.new(2026, 6, 30), 600_001,
      acceptance_required: true)
    activate_contract
    Contracts::AllocateTransactionPrice.call(
      contract: @contract, actor: @org.user, effective_date: Date.new(2026, 4, 1)
    )

    schedule = Contracts::GenerateRevenueSchedules.call(contract: @contract, actor: @org.user).sole

    assert_equal "milestone", schedule.method
    assert_equal [ 400_000, 600_001 ], schedule.contract_schedule_lines.order(:sequence).pluck(:amount_minor)
    assert_equal [ first.id, second.id ], schedule.contract_schedule_lines.order(:sequence).pluck(:contract_milestone_id)
    error = assert_raises(ActiveRecord::RecordInvalid) do
      Contracts::Milestones.achieve!(
        milestone: second, actor: @org.user, achieved_date: Date.new(2026, 6, 30)
      )
    end
    assert_includes error.record.errors.full_messages, "Acceptance date is required when an acceptance milestone is achieved"

    Contracts::Milestones.achieve!(
      milestone: second.reload, actor: @org.user, achieved_date: Date.new(2026, 6, 30),
      acceptance_date: Date.new(2026, 6, 30)
    )
    assert_equal "achieved", second.reload.status
    assert_equal "contract.milestone_achieved", DomainEvent.for_tenant(@org.tenant.id).in_order.last.action
  end

  test "a schedule refuses milestone amounts that do not reconcile to allocation" do
    obligation = add_obligation(
      description: "Implementation", satisfaction: "point_in_time",
      standalone_selling_price_minor: 1_000_001, ssp_method: "observable"
    )
    add_milestone(obligation, "Incomplete allocation", Date.new(2026, 6, 30), 999_999)
    activate_contract
    Contracts::AllocateTransactionPrice.call(
      contract: @contract, actor: @org.user, effective_date: Date.new(2026, 4, 1)
    )

    error = assert_raises(Contracts::InvalidContract) do
      Contracts::GenerateRevenueSchedules.call(contract: @contract, actor: @org.user)
    end
    assert_match(/milestones total 999999.*allocated price is 1000001/, error.message)
    assert_equal 0, ContractSchedule.where(contract: @contract).count
  end

  private

  def add_obligation(attributes)
    Contracts::PerformanceObligations.create!(
      contract: @contract, attributes: attributes, actor: @org.user
    )
  end

  def add_milestone(obligation, description, planned_date, amount, **attributes)
    Contracts::Milestones.create!(
      obligation: obligation, actor: @org.user,
      attributes: attributes.merge(
        description: description, planned_date: planned_date,
        recognition_amount_minor: amount, triggers_recognition: true
      )
    )
  end

  def activate_contract
    Contracts::Transition.call(
      contract: @contract, to: "signed", actor: @org.user, occurred_on: Date.new(2026, 3, 31)
    )
    Contracts::Transition.call(
      contract: @contract, to: "active", actor: @org.user, occurred_on: Date.new(2026, 4, 1)
    )
  end
end
