# frozen_string_literal: true

class InventoriesController < BrowserController
  before_action -> { require_capability!("inventory.read") }, only: :show
  before_action -> { require_capability!("inventory.post") }, only: :create
  before_action -> { require_capability!("inventory.manage") }, only: :create_warehouse

  def show
    load_inventory
  end

  def create
    transaction = Inventory::PostMovement.call(
      tenant: Current.tenant, actor: Current.user, attributes: movement_params
    )
    redirect_to inventory_path(tenant_route_options),
      notice: "#{transaction.transaction_type.humanize} posted at moving-average value " \
        "#{helpers.money_amount(transaction.total_value_minor)}."
  rescue Inventory::InvalidMovement, ActiveRecord::RecordInvalid,
         Posting::PeriodClosedError, Posting::PeriodRestrictedError => e
    load_inventory
    flash.now[:alert] = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
    render :show, status: :unprocessable_entity
  end

  def create_warehouse
    warehouse = Inventory::ManageWarehouse.create!(
      tenant: Current.tenant, actor: Current.user,
      attributes: warehouse_params.to_h.symbolize_keys
    )
    redirect_to inventory_path(tenant_route_options),
      notice: "#{warehouse.code} · #{warehouse.name} added."
  rescue ActiveRecord::RecordInvalid => e
    load_inventory
    flash.now[:alert] = e.record.errors.full_messages.to_sentence
    render :show, status: :unprocessable_entity
  end

  private

  def load_inventory
    @items = Item.active.where(tenant_id: Current.tenant.id, item_type: "good").order(:code)
    @warehouses = Warehouse.active.where(tenant_id: Current.tenant.id).order(:code)
    @balances = StockBalance.where(tenant_id: Current.tenant.id)
      .includes(:item, :warehouse).order("items.code", "warehouses.code")
      .references(:item, :warehouse)
    @transactions = InventoryTransaction.where(tenant_id: Current.tenant.id)
      .includes(:item, :source_warehouse, :destination_warehouse).order(created_at: :desc).limit(100)
    @offset_accounts = Account.active.where(tenant_id: Current.tenant.id).in_code_order
  end

  def movement_params
    params.require(:inventory_movement).permit(
      :transaction_type, :posting_date, :item_id, :quantity, :unit_cost,
      :source_warehouse_id, :destination_warehouse_id, :offset_account_code,
      :external_reference, :reason, :idempotency_key
    )
  end

  def warehouse_params
    params.require(:warehouse).permit(:code, :name, :warehouse_type)
  end
end
