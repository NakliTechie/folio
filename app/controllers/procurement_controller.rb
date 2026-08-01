# frozen_string_literal: true

class ProcurementController < BrowserController
  before_action -> { require_capability!("procurement.read") }, only: :show
  before_action -> { require_capability!("procurement.manage") }, only: %i[onboard_vendor create_order]
  before_action -> { require_capability!("procurement.approve") },
    only: %i[approve_vendor suspend_vendor approve_order close_order]
  before_action -> { require_capability!("procurement.receive") }, only: :receive_order

  def show
    load_show
  end

  def onboard_vendor
    profile = Procurement::ManageVendor.onboard!(
      tenant: Current.tenant, actor: Current.user, attributes: vendor_params
    )
    redirect_to procurement_path(tenant_route_options),
      notice: "#{profile.party.name} is pending independent approval."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, Procurement::InvalidProcurement => e
    render_error(e)
  end

  def approve_vendor
    profile = vendor_scope.find(params[:id])
    Procurement::ManageVendor.approve!(profile: profile, actor: Current.user)
    redirect_to procurement_path(tenant_route_options), notice: "#{profile.party.name} approved."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, Procurement::InvalidProcurement => e
    render_error(e)
  end

  def suspend_vendor
    profile = vendor_scope.find(params[:id])
    Procurement::ManageVendor.suspend!(profile: profile, actor: Current.user, reason: params[:reason])
    redirect_to procurement_path(tenant_route_options), notice: "#{profile.party.name} suspended."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, Procurement::InvalidProcurement => e
    render_error(e)
  end

  def create_order
    order = Procurement::CreateOrder.call(
      tenant: Current.tenant, actor: Current.user,
      attributes: order_params.except(:lines), lines: order_params[:lines]
    )
    redirect_to procurement_path(tenant_route_options),
      notice: "#{order.order_number} drafted for independent approval."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, Procurement::InvalidProcurement,
         CurrencyProfile::UnsupportedCurrency => e
    render_error(e)
  end

  def approve_order
    order = order_scope.find(params[:id])
    Procurement::ApproveOrder.call(order: order, actor: Current.user)
    redirect_to procurement_path(tenant_route_options), notice: "#{order.order_number} approved."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, Procurement::InvalidProcurement => e
    render_error(e)
  end

  def receive_order
    order = order_scope.find(params[:id])
    receipt = Procurement::ReceiveOrder.call(
      order: order, actor: Current.user,
      attributes: receipt_params.except(:lines), lines: receipt_params[:lines]
    )
    redirect_to procurement_path(tenant_route_options), notice: "#{receipt.receipt_number} recorded."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, Procurement::InvalidProcurement,
         Inventory::InvalidMovement, Posting::PeriodClosedError, Posting::PeriodRestrictedError => e
    render_error(e)
  end

  def close_order
    order = order_scope.find(params[:id])
    Procurement::CloseOrder.call(order: order, actor: Current.user)
    redirect_to procurement_path(tenant_route_options), notice: "#{order.order_number} closed."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, Procurement::InvalidProcurement => e
    render_error(e)
  end

  private

  def load_show
    @vendors = vendor_scope.includes(:party, :created_by, :approved_by).order(created_at: :desc)
    profiled_ids = @vendors.pluck(:party_id)
    @vendor_parties = Party.active.joins(:party_roles).where(
      tenant_id: Current.tenant.id, party_roles: { role: "vendor" }
    ).where.not(id: profiled_ids).distinct.order(:name)
    @approved_vendors = @vendors.select(&:orderable?)
    @items = Item.active.where(tenant_id: Current.tenant.id).order(:code)
    @warehouses = Warehouse.active.where(tenant_id: Current.tenant.id).order(:code)
    @orders = order_scope.includes(
      { vendor_profile: :party }, :created_by, :approved_by,
      purchase_order_lines: [ :item, :warehouse ]
    ).order(order_date: :desc, id: :desc)
  end

  def vendor_scope
    VendorProfile.where(tenant_id: Current.tenant.id)
  end

  def order_scope
    PurchaseOrder.where(tenant_id: Current.tenant.id)
  end

  def vendor_params
    params.require(:vendor_profile).permit(:party_id, :payment_terms_days, :preferred_currency)
  end

  def order_params
    params.require(:purchase_order).permit(
      :vendor_profile_id, :order_date, :expected_on, :description,
      lines: %i[item_id warehouse_id quantity unit_price]
    )
  end

  def receipt_params
    params.require(:goods_receipt).permit(
      :received_on, :external_reference, :idempotency_key,
      lines: %i[purchase_order_line_id quantity]
    )
  end

  def render_error(error)
    load_show
    flash.now[:alert] = error.respond_to?(:record) ? error.record.errors.full_messages.to_sentence : error.message
    render :show, status: :unprocessable_entity
  end
end
