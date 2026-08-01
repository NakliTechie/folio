# frozen_string_literal: true

class ContractsController < BrowserController
  before_action -> { require_capability!("contracts.read") }, only: %i[index show]
  before_action -> { require_capability!("contracts.manage") }, only: %i[
    new create edit update create_performance_obligation create_milestone
  ]
  before_action -> { require_capability!("contracts.approve") }, only: %i[
    sign activate close achieve_milestone allocate_transaction_price generate_revenue_schedules
  ]
  before_action -> { require_capability!("contracts.post") }, only: :run_revenue_recognition
  before_action :set_contract, only: %i[
    show edit update sign activate close create_performance_obligation create_milestone
    achieve_milestone allocate_transaction_price generate_revenue_schedules
    run_revenue_recognition
  ]

  def index
    @contracts = contract_scope.includes(:party).in_number_order
  end

  def show
    @events = DomainEvent.for_tenant(Current.tenant.id)
      .where(ref: @contract.contract_number).in_order
    @obligations = @contract.contract_performance_obligations
      .includes(:contract_milestones).in_number_order
    @latest_allocation = @contract.contract_allocation_runs
      .includes(contract_allocation_lines: :contract_performance_obligation)
      .in_version_order.last
    @schedules = @contract.contract_schedules
      .includes(:contract_performance_obligation, :contract_schedule_lines)
      .order(version: :desc, id: :asc)
    @posting_runs = @contract.contract_posting_runs.order(created_at: :desc).limit(10)
  end

  def new
    @contract = contract_scope.new(default_attributes)
    load_form
  end

  def create
    @contract = Contracts::Create.call(
      tenant: Current.tenant,
      party_id: contract_params[:party_id],
      attributes: normalized_attributes,
      actor: Current.user
    )
    redirect_to contract_path(@contract, tenant_route_options),
      notice: "#{@contract.contract_number} drafted. Review the evidence and commercial terms before signing."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound,
         Contracts::InvalidContract, CurrencyProfile::UnsupportedCurrency => e
    @contract ||= contract_scope.new(form_attributes)
    load_form
    flash.now[:alert] = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
    render :new, status: :unprocessable_entity
  end

  def edit
    redirect_to contract_path(@contract, tenant_route_options),
      alert: "Only a draft contract can be edited." unless @contract.status == "draft"
    load_form unless performed?
  end

  def update
    Contracts::Update.call(contract: @contract, attributes: normalized_attributes, actor: Current.user)
    redirect_to contract_path(@contract, tenant_route_options), notice: "Contract draft updated."
  rescue ActiveRecord::RecordInvalid, Contracts::InvalidContract,
         CurrencyProfile::UnsupportedCurrency => e
    @contract.assign_attributes(form_attributes)
    load_form
    flash.now[:alert] = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
    render :edit, status: :unprocessable_entity
  end

  def sign
    transition!("signed", params[:execution_date])
  end

  def activate
    transition!("active", params[:effective_date])
  end

  def close
    transition!("closed", params[:closed_on])
  end

  def create_performance_obligation
    Contracts::PerformanceObligations.create!(
      contract: @contract, actor: Current.user,
      attributes: performance_obligation_attributes
    )
    redirect_to contract_path(@contract, tenant_route_options),
      notice: "Performance obligation added."
  rescue ActiveRecord::RecordInvalid, Contracts::InvalidContract => e
    redirect_with_contract_error(e)
  end

  def create_milestone
    obligation = @contract.contract_performance_obligations.find(milestone_params[:obligation_id])
    Contracts::Milestones.create!(
      obligation: obligation, actor: Current.user, attributes: milestone_attributes
    )
    redirect_to contract_path(@contract, tenant_route_options), notice: "Milestone added."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, Contracts::InvalidContract => e
    redirect_with_contract_error(e)
  end

  def achieve_milestone
    milestone = @contract.contract_milestones.find(params[:milestone_id])
    Contracts::Milestones.achieve!(
      milestone: milestone, actor: Current.user,
      achieved_date: params[:achieved_date].presence || business_date,
      acceptance_date: params[:acceptance_date].presence
    )
    redirect_to contract_path(@contract, tenant_route_options), notice: "Milestone achieved."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, Contracts::InvalidContract => e
    redirect_with_contract_error(e)
  end

  def allocate_transaction_price
    run = Contracts::AllocateTransactionPrice.call(
      contract: @contract, actor: Current.user,
      effective_date: params[:effective_date].presence || business_date,
      trigger: "initial"
    )
    redirect_to contract_path(@contract, tenant_route_options),
      notice: "Transaction price allocated in version #{run.version}."
  rescue ActiveRecord::RecordInvalid, Contracts::InvalidContract => e
    redirect_with_contract_error(e)
  end

  def generate_revenue_schedules
    schedules = Contracts::GenerateRevenueSchedules.call(contract: @contract, actor: Current.user)
    redirect_to contract_path(@contract, tenant_route_options),
      notice: "Generated #{schedules.size} revenue #{'schedule'.pluralize(schedules.size)}."
  rescue ActiveRecord::RecordInvalid, Contracts::InvalidContract => e
    redirect_with_contract_error(e)
  end

  def run_revenue_recognition
    run = Contracts::RunRevenueRecognition.call(
      contract: @contract, actor: Current.user,
      posting_date: params[:posting_date].presence || business_date,
      mode: params[:mode], idempotency_key: params.require(:idempotency_key)
    )
    verb = run.mode == "simulate" ? "simulated" : "posted"
    redirect_to contract_path(@contract, tenant_route_options),
      notice: "Revenue run #{verb}: #{run.result.fetch("revenue_minor", 0)} minor units across " \
        "#{run.result.fetch(run.mode == "simulate" ? "simulated" : "posted", 0)} lines."
  rescue ActiveRecord::RecordInvalid, Contracts::InvalidContract,
         Contracts::RunRevenueRecognition::NotPermitted, Posting::PeriodClosedError,
         Posting::PeriodRestrictedError, Posting::UnbalancedError => e
    redirect_with_contract_error(e)
  end

  private

  def contract_scope
    Contract.where(tenant_id: Current.tenant.id)
  end

  def set_contract
    @contract = contract_scope.find(params[:id])
  end

  def transition!(target, date)
    Contracts::Transition.call(
      contract: @contract, to: target, actor: Current.user,
      occurred_on: date.presence || business_date
    )
    redirect_to contract_path(@contract, tenant_route_options),
      notice: "#{@contract.contract_number} is now #{@contract.status}."
  rescue ActiveRecord::RecordInvalid, Contracts::InvalidTransition => e
    redirect_to contract_path(@contract, tenant_route_options),
      alert: e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
  end

  def redirect_with_contract_error(error)
    message = error.respond_to?(:record) ? error.record.errors.full_messages.to_sentence : error.message
    redirect_to contract_path(@contract, tenant_route_options), alert: message
  end

  def load_form
    @customers = Party.active.joins(:party_roles)
      .where(tenant_id: Current.tenant.id, party_roles: { role: "customer" })
      .distinct.order(:name)
  end

  def default_attributes
    {
      side: "sell", status: "draft", contract_type: "service_agreement",
      term_type: "fixed", currency: Current.tenant.functional_currency,
      jurisdiction: "IN", stamp_status: "pending", signature_status: "unsigned",
      registration_required: false, registration_status: "not_required",
      gst_treatment: "domestic_b2b", effective_date: business_date
    }
  end

  def normalized_attributes
    values = contract_params.to_h.symbolize_keys.except(
      :party_id, :total_contract_value, :stamp_amount
    ).merge(
      currency: Current.tenant.functional_currency,
      total_contract_value_minor: money_minor(contract_params[:total_contract_value], "contract value")
    )
    if contract_params[:stamp_amount].present?
      values[:stamp_amount_minor] = money_minor(contract_params[:stamp_amount], "stamp amount")
    end
    values
  end

  def money_minor(value, label)
    currency = Current.tenant.functional_currency
    exponent = CurrencyProfile.exponent_for!(currency)
    decimal = Documents::DecimalInput.parse!(
      value, label: label, scale: exponent, minimum: 0,
      error_class: Contracts::InvalidContract
    )
    (decimal * (10**exponent)).to_i
  end

  def form_attributes
    contract_params.except(:total_contract_value, :stamp_amount)
  end

  def contract_params
    params.require(:contract).permit(
      :party_id, :title, :contract_type, :effective_date, :end_date,
      :enforceable_period_end, :term_type, :auto_renew, :renewal_notice_days,
      :total_contract_value, :jurisdiction, :instrument_type, :execution_date,
      :stamp_status, :stamp_state_code, :stamp_amount, :stamp_certificate_reference,
      :stamp_date, :signature_status, :registration_required, :registration_status,
      :registration_reference, :tds_section, :gst_treatment,
      :place_of_supply_state_code, :hsn_sac_code
    )
  end

  def performance_obligation_attributes
    values = params.require(:performance_obligation).permit(
      :description, :distinct, :series, :material_right, :satisfaction,
      :over_time_criterion, :progress_measure, :standalone_selling_price,
      :ssp_method, :service_start_date, :service_end_date, :revenue_account_code
    ).to_h.symbolize_keys
    values[:standalone_selling_price_minor] = money_minor(
      values.delete(:standalone_selling_price), "standalone selling price"
    )
    values
  end

  def milestone_attributes
    values = milestone_params.except(:obligation_id, :recognition_amount).to_h.symbolize_keys
    values[:recognition_amount_minor] = money_minor(
      milestone_params[:recognition_amount], "recognition amount"
    )
    values
  end

  def milestone_params
    params.require(:milestone).permit(
      :obligation_id, :description, :planned_date, :recognition_amount,
      :triggers_billing, :triggers_recognition, :acceptance_required
    )
  end
end
