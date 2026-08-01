# frozen_string_literal: true

class ControllingController < BrowserController
  before_action -> { require_capability!("controlling.read") }, only: :show
  before_action -> { require_capability!("controlling.manage") },
    only: %i[create_segment create_profit_center create_cost_center create_plan create_cycle]
  before_action -> { require_capability!("controlling.allocate") }, only: :run_allocation

  def show
    load_show
  end

  def create_segment
    record = Controlling::Manage.create_segment!(
      tenant: Current.tenant, actor: Current.user, attributes: segment_params
    )
    redirect_to controlling_path(tenant_route_options), notice: "Segment #{record.code} added."
  rescue ActiveRecord::RecordInvalid => e
    render_error(e)
  end

  def create_profit_center
    record = Controlling::Manage.create_profit_center!(
      tenant: Current.tenant, actor: Current.user, attributes: profit_center_params
    )
    redirect_to controlling_path(tenant_route_options), notice: "Profit center #{record.code} added."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
    render_error(e)
  end

  def create_cost_center
    record = Controlling::Manage.create_cost_center!(
      tenant: Current.tenant, actor: Current.user, attributes: cost_center_params
    )
    redirect_to controlling_path(tenant_route_options), notice: "Cost center #{record.code} added."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
    render_error(e)
  end

  def create_plan
    line = Controlling::Manage.create_plan_line!(
      tenant: Current.tenant, actor: Current.user, attributes: plan_params
    )
    redirect_to controlling_path(tenant_route_options),
      notice: "#{line.version} plan saved for period #{line.period_no}."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, Controlling::InvalidControl => e
    render_error(e)
  end

  def create_cycle
    cycle = Controlling::Manage.create_cycle!(
      tenant: Current.tenant, actor: Current.user, attributes: cycle_params,
      receivers: receiver_params
    )
    redirect_to controlling_path(tenant_route_options), notice: "Allocation cycle #{cycle.code} added."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, Controlling::InvalidControl => e
    render_error(e)
  end

  def run_allocation
    cycle = AllocationCycle.where(tenant_id: Current.tenant.id).find(params[:id])
    run = Controlling::RunAllocation.call(
      cycle: cycle, actor: Current.user, attributes: allocation_params
    )
    redirect_to controlling_path(tenant_route_options),
      notice: "Allocation #{run.status}: #{helpers.money_amount(run.allocated_amount_minor)} distributed."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, Controlling::InvalidControl,
         Posting::PeriodClosedError, Posting::PeriodRestrictedError => e
    render_error(e)
  end

  private

  def load_show
    @segments = ControllingSegment.active.where(tenant_id: Current.tenant.id).order(:code)
    @profit_centers = ProfitCenter.active.includes(:controlling_segment)
      .where(tenant_id: Current.tenant.id).order(:code)
    @cost_centers = CostCenter.active.includes(profit_center: :controlling_segment)
      .where(tenant_id: Current.tenant.id).order(:code)
    @expense_accounts = Account.active.where(
      tenant_id: Current.tenant.id, account_type: "expense"
    ).in_code_order
    @plan_lines = ControllingPlanLine.where(tenant_id: Current.tenant.id)
      .includes(:cost_center).order(fiscal_year: :desc, period_no: :desc, id: :desc).limit(100)
    @plan_actuals = @plan_lines.index_with { |line| actual_for(line) }
    @cycles = AllocationCycle.active.where(tenant_id: Current.tenant.id)
      .includes(:sender_cost_center, allocation_receivers: :cost_center).order(:code)
    @runs = AllocationRun.where(tenant_id: Current.tenant.id)
      .includes(:allocation_cycle).order(created_at: :desc).limit(20)
    entity = Entity.find_by!(tenant_id: Current.tenant.id, code: "PRIMARY")
    @current_fiscal_year = Documents.fiscal_year(business_date, variant: entity.fiscal_year_variant)
    @current_period = Documents.period_no(business_date, variant: entity.fiscal_year_variant)
  end

  def actual_for(line)
    center = line.cost_center
    range = PeriodControls::Calendar.date_range(
      entity: center.entity, fiscal_year: line.fiscal_year, period_no: line.period_no
    )
    JournalEntryLineAmount.joins(entry_line: :entry).where(
      entry_lines: {
        tenant_id: Current.tenant.id, cost_object_type: "cost_center",
        cost_object_id: center.id, account_code: line.account_code
      },
      entries: { posting_date: range }, slot_role: "transaction", currency: line.currency
    ).sum(:amount_minor)
  end

  def segment_params
    params.require(:controlling_segment).permit(:code, :name)
  end

  def profit_center_params
    params.require(:profit_center).permit(:code, :name, :controlling_segment_id, :valid_from, :valid_to)
  end

  def cost_center_params
    params.require(:cost_center).permit(:code, :name, :profit_center_id, :valid_from, :valid_to)
  end

  def plan_params
    params.require(:controlling_plan).permit(
      :cost_center_id, :account_code, :version, :fiscal_year, :period_no, :amount
    )
  end

  def cycle_params
    params.require(:allocation_cycle).permit(
      :code, :name, :sender_cost_center_id, :source_account_code, :valid_from, :valid_to
    )
  end

  def receiver_params
    values = params.require(:allocation_cycle).permit(
      :receiver_1_id, :receiver_1_weight, :receiver_2_id, :receiver_2_weight,
      :receiver_3_id, :receiver_3_weight
    )
    1.upto(3).map do |index|
      {
        cost_center_id: values["receiver_#{index}_id"],
        weight_basis_points: percent_basis_points(values["receiver_#{index}_weight"])
      }
    end
  end

  def percent_basis_points(raw)
    return if raw.blank?

    (Documents::DecimalInput.parse!(
      raw, label: "receiver weight", scale: 2, minimum: 0,
      error_class: Controlling::InvalidControl
    ) * 100).to_i
  end

  def allocation_params
    params.permit(:through_date, :posting_date, :mode, :idempotency_key)
  end

  def render_error(error)
    load_show
    flash.now[:alert] = error.respond_to?(:record) ? error.record.errors.full_messages.to_sentence : error.message
    render :show, status: :unprocessable_entity
  end
end
