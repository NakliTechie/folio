# frozen_string_literal: true

class ExchangeRatesController < BrowserController
  before_action -> { require_capability!("currency.read") }, only: :index
  before_action -> { require_capability!("currency.manage") }, only: :create
  before_action -> { require_capability!("currency.post") }, only: :run_revaluation

  def index
    load_index
  end

  def create
    rate = ForeignExchange::Rates.create!(
      tenant: Current.tenant, attributes: rate_params, actor: Current.user
    )
    redirect_to exchange_rates_path(tenant_route_options),
      notice: "#{rate.rate_type.humanize} rate #{rate.from_currency}/#{rate.to_currency} recorded."
  rescue ActiveRecord::RecordInvalid => e
    load_index
    flash.now[:alert] = e.record.errors.full_messages.to_sentence
    render :index, status: :unprocessable_entity
  end

  def run_revaluation
    run = ForeignExchange::Revalue.call(
      tenant: Current.tenant, actor: Current.user,
      revaluation_date: params[:revaluation_date].presence || business_date,
      mode: params[:mode], idempotency_key: params.require(:idempotency_key)
    )
    redirect_to exchange_rates_path(tenant_route_options),
      notice: "Foreign-currency revaluation #{run.status}: " \
        "#{run.result.fetch('positionCount')} monetary positions reviewed."
  rescue ActiveRecord::RecordInvalid, ArgumentError, ForeignExchange::MissingRate,
         ForeignExchange::Revalue::NotPermitted, Posting::PeriodClosedError,
         Posting::PeriodRestrictedError, Posting::UnbalancedError => e
    redirect_to exchange_rates_path(tenant_route_options), alert: e.message
  end

  private

  def load_index
    @exchange_rates = ExchangeRate.where(tenant_id: Current.tenant.id)
      .order(effective_on: :desc, from_currency: :asc, to_currency: :asc)
    @revaluation_runs = ExchangeRevaluationRun.where(tenant_id: Current.tenant.id)
      .order(created_at: :desc).limit(10)
  end

  def rate_params
    params.require(:exchange_rate).permit(
      :from_currency, :to_currency, :effective_on, :rate, :rate_type, :source
    )
  end
end
