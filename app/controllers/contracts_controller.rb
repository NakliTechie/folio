# frozen_string_literal: true

class ContractsController < BrowserController
  before_action -> { require_capability!("contracts.read") }, only: %i[index show]
  before_action -> { require_capability!("contracts.manage") }, only: %i[new create edit update]
  before_action -> { require_capability!("contracts.approve") }, only: %i[sign activate close]
  before_action :set_contract, only: %i[show edit update sign activate close]

  def index
    @contracts = contract_scope.includes(:party).in_number_order
  end

  def show
    @events = DomainEvent.for_tenant(Current.tenant.id)
      .where(ref: @contract.contract_number).in_order
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
end
