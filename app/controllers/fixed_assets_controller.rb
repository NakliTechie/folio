# frozen_string_literal: true

class FixedAssetsController < BrowserController
  before_action -> { require_capability!("assets.read") }, only: :index
  before_action -> { require_capability!("assets.manage") }, only: %i[create create_class]
  before_action -> { require_capability!("assets.post") }, only: %i[acquire retire run_depreciation]

  def index
    load_index
  end

  def create
    asset = FixedAssets::Manage.create!(
      tenant: Current.tenant, actor: Current.user, attributes: fixed_asset_params,
      book_terms: valuation_terms(:book), tax_terms: valuation_terms(:tax)
    )
    redirect_to fixed_assets_path(tenant_route_options),
      notice: "#{asset.identity} · #{asset.name} created with BOOK and TAX_IT valuations."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, FixedAssets::InvalidAsset => e
    render_error(e)
  end

  def create_class
    klass = FixedAssets::ManageClass.create!(
      tenant: Current.tenant, actor: Current.user, attributes: asset_class_params
    )
    redirect_to fixed_assets_path(tenant_route_options), notice: "Asset class #{klass.code} added."
  rescue ActiveRecord::RecordInvalid => e
    render_error(e)
  end

  def acquire
    asset = asset_scope.find(params[:id])
    transaction = FixedAssets::Acquire.call(
      asset: asset, actor: Current.user, attributes: acquisition_params
    )
    redirect_to fixed_assets_path(tenant_route_options),
      notice: "#{asset.identity} capitalized at #{helpers.money_amount(transaction.amount_minor)}."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, FixedAssets::InvalidAsset,
         Posting::PeriodClosedError, Posting::PeriodRestrictedError => e
    render_error(e)
  end

  def run_depreciation
    run = FixedAssets::RunDepreciation.call(
      tenant: Current.tenant, actor: Current.user, attributes: depreciation_params
    )
    redirect_to fixed_assets_path(tenant_route_options),
      notice: "Depreciation #{run.status}: #{run.result.fetch('assetCount')} assets, " \
        "#{helpers.money_amount(run.result.fetch('ledgerAmountMinor'))} to the book ledger."
  rescue ActiveRecord::RecordInvalid, FixedAssets::InvalidAsset,
         Posting::PeriodClosedError, Posting::PeriodRestrictedError => e
    render_error(e)
  end

  def retire
    asset = asset_scope.find(params[:id])
    transaction = FixedAssets::Retire.call(
      asset: asset, actor: Current.user, attributes: retirement_params
    )
    redirect_to fixed_assets_path(tenant_route_options),
      notice: "#{asset.identity} retired; its book carrying amount was cleared. " \
        "Event #{transaction.ledger_event_id}."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, FixedAssets::InvalidAsset,
         Posting::PeriodClosedError, Posting::PeriodRestrictedError => e
    render_error(e)
  end

  private

  def load_index
    @asset_classes = AssetClass.active.where(tenant_id: Current.tenant.id).order(:code)
    @fixed_assets = asset_scope.includes(:asset_class, :asset_valuations).in_identity_order
    @transactions = AssetTransaction.where(tenant_id: Current.tenant.id)
      .includes(:fixed_asset).order(asset_value_date: :desc, id: :desc).limit(100)
    @depreciation_runs = DepreciationRun.where(tenant_id: Current.tenant.id)
      .order(created_at: :desc).limit(10)
    @offset_accounts = Account.active.where(tenant_id: Current.tenant.id).in_code_order
    @asset_accounts = @offset_accounts.select { |account| account.account_type == "asset" }
    @expense_accounts = @offset_accounts.select { |account| account.account_type == "expense" }
    @income_accounts = @offset_accounts.select { |account| account.account_type == "income" }
  end

  def asset_scope
    FixedAsset.where(tenant_id: Current.tenant.id)
  end

  def fixed_asset_params
    params.require(:fixed_asset).permit(
      :asset_class_id, :asset_number, :component_number, :name, :description,
      :capitalization_date, :quantity, :unit_of_measure, :serial_number,
      :inventory_number, :manufacturer
    )
  end

  def valuation_terms(prefix)
    values = params.require(:fixed_asset).permit(
      "#{prefix}_useful_life_months", "#{prefix}_residual_value", "#{prefix}_depreciation_start_date"
    )
    {
      useful_life_months: values["#{prefix}_useful_life_months"],
      residual_value_minor: money_minor(values["#{prefix}_residual_value"].presence || "0"),
      depreciation_start_date: values["#{prefix}_depreciation_start_date"]
    }
  end

  def acquisition_params
    params.require(:acquisition).permit(
      :amount, :offset_account_code, :asset_value_date, :posting_date,
      :external_reference, :idempotency_key
    )
  end

  def depreciation_params
    params.permit(:through_date, :posting_date, :mode, :idempotency_key)
  end

  def retirement_params
    params.require(:retirement).permit(
      :retirement_date, :proceeds, :proceeds_account_code,
      :reason, :idempotency_key
    )
  end

  def asset_class_params
    params.require(:asset_class).permit(
      :code, :name, :apc_account_code, :accumulated_depreciation_account_code,
      :depreciation_expense_account_code, :gain_account_code, :loss_account_code,
      :default_useful_life_months
    )
  end

  def money_minor(value)
    exponent = CurrencyProfile.exponent_for!(Current.tenant.functional_currency)
    amount = Documents::DecimalInput.parse!(
      value, label: "residual value", scale: exponent, minimum: 0,
      error_class: FixedAssets::InvalidAsset
    )
    (amount * (10**exponent)).to_i
  end

  def render_error(error)
    load_index
    flash.now[:alert] = error.respond_to?(:record) ? error.record.errors.full_messages.to_sentence : error.message
    render :index, status: :unprocessable_entity
  end
end
