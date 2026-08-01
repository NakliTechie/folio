# frozen_string_literal: true

class ConsolidationController < BrowserController
  before_action -> { require_capability!("consolidation.read") }, only: :show
  before_action -> { require_capability!("consolidation.manage") }, only: :create_entity
  before_action -> { require_capability!("consolidation.post") }, only: %i[post_intercompany eliminate]

  def show
    load_show
  end

  def create_entity
    entity = Consolidation::Manage.create_entity!(
      tenant: Current.tenant, group: current_group, actor: Current.user,
      attributes: entity_params
    )
    redirect_to consolidation_path(tenant_route_options), notice: "#{entity.code} added to the group."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound,
         Consolidation::InvalidConsolidation => e
    render_error(e)
  end

  def post_intercompany
    transaction = Consolidation::PostIntercompany.call(
      group: current_group, actor: Current.user, attributes: intercompany_params
    )
    redirect_to consolidation_path(tenant_route_options),
      notice: "#{transaction.transaction_code} posted to both legal entities."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound,
         Consolidation::InvalidConsolidation, Posting::PeriodClosedError,
         Posting::PeriodRestrictedError => e
    render_error(e)
  end

  def eliminate
    transaction = current_group.intercompany_transactions.find(params[:id])
    run = Consolidation::Eliminate.call(
      transaction: transaction, actor: Current.user,
      attributes: params.permit(:posting_date, :idempotency_key)
    )
    redirect_to consolidation_path(tenant_route_options.merge(as_of: run.posting_date)),
      notice: "#{transaction.transaction_code} eliminated from the group view."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound,
         Consolidation::InvalidConsolidation, Posting::PeriodClosedError,
         Posting::PeriodRestrictedError => e
    render_error(e)
  end

  private

  def load_show
    @group = current_group
    @entities = @group.entities.order(:code)
    @transactions = @group.intercompany_transactions.includes(
      :seller_entity, :buyer_entity, :consolidation_elimination_run
    ).order(posting_date: :desc, id: :desc)
    @asset_accounts = account_options("asset")
    @liability_accounts = account_options("liability")
    @income_accounts = account_options("income")
    @expense_accounts = account_options("expense")
    @as_of = parse_as_of
    @report = Consolidation::Report.trial_balance(group: @group, as_of: @as_of)
  end

  def current_group
    @current_group ||= ConsolidationGroup.find_by!(tenant_id: Current.tenant.id, code: "GROUP")
  end

  def account_options(type)
    Account.active.where(tenant_id: Current.tenant.id, account_type: type).in_code_order
  end

  def entity_params
    params.require(:entity).permit(:code, :legal_name, :office_name, :effective_from)
  end

  def intercompany_params
    params.require(:intercompany_transaction).permit(
      :seller_entity_id, :buyer_entity_id, :posting_date, :amount, :description,
      :seller_receivable_account_code, :seller_revenue_account_code,
      :buyer_expense_account_code, :buyer_payable_account_code, :idempotency_key
    )
  end

  def parse_as_of
    params[:as_of].present? ? Date.iso8601(params[:as_of]) : business_date
  rescue Date::Error
    business_date
  end

  def render_error(error)
    load_show
    flash.now[:alert] = error.respond_to?(:record) ? error.record.errors.full_messages.to_sentence : error.message
    render :show, status: :unprocessable_entity
  end
end
