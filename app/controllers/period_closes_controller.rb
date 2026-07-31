# frozen_string_literal: true

class PeriodClosesController < BrowserController
  before_action -> { require_capability!("reports.read") }, only: :show
  before_action -> { require_capability!("period.lock") }, only: :update

  def show
    load_period
  end

  def update
    PeriodControls::Manage.call(
      tenant: Current.tenant,
      fiscal_year: period_control_params[:fiscal_year],
      period_no: period_control_params[:period_no],
      state: period_control_params[:state],
      actor: Current.user
    )
    redirect_to period_close_path(
      tenant_route_options.merge(
        fiscal_year: period_control_params[:fiscal_year],
        period_no: period_control_params[:period_no]
      )
    ), notice: "Posting period is now #{period_control_params[:state]}."
  rescue PeriodControls::InvalidControl, ActiveRecord::RecordInvalid => e
    load_period
    flash.now[:alert] = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
    render :show, status: :unprocessable_entity
  end

  private

  def load_period
    entity = Entity.find_by!(tenant_id: Current.tenant.id, code: "PRIMARY")
    today = business_date
    default_year = Documents.fiscal_year(today, variant: entity.fiscal_year_variant)
    default_period = Documents.period_no(today, variant: entity.fiscal_year_variant)
    @fiscal_year = integer_param(:fiscal_year, default_year)
    @period_no = integer_param(:period_no, default_period)
    @readiness = PeriodControls::Readiness.call(
      tenant: Current.tenant, fiscal_year: @fiscal_year, period_no: @period_no
    )
    known_years = Entry.where(tenant_id: Current.tenant.id).distinct.pluck(:fiscal_year)
      .select { |year| (1900..9998).cover?(year) }
    @fiscal_years = (known_years + ((default_year - 2)..(default_year + 1)).to_a).uniq.sort.reverse
    @periods = (0..16).map do |period|
      [ PeriodControls::Calendar.label(entity: entity, fiscal_year: @fiscal_year, period_no: period), period ]
    end
    @history = LedgerEvent.for_tenant(Current.tenant.id).where(action: PeriodControl::STATES.map { |state| "period.#{state}" })
      .in_order.last(10).reverse
  end

  def integer_param(key, fallback)
    params[key].present? ? Integer(params[key], 10) : fallback
  rescue ArgumentError, TypeError
    raise PeriodControls::InvalidControl, "#{key.to_s.humanize} must be a valid number"
  end

  def period_control_params
    params.require(:period_control).permit(:fiscal_year, :period_no, :state)
  end
end
