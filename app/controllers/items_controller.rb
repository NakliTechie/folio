# frozen_string_literal: true

class ItemsController < BrowserController
  before_action -> { require_capability!("masters.read") }, only: :index
  before_action -> { require_capability!("masters.manage") },
    only: %i[new create edit update deactivate reactivate]
  before_action :set_item, only: %i[edit update deactivate reactivate]

  def index
    @items = item_scope.order(:code)
  end

  def new
    @item = item_scope.new(
      item_type: "service", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
      cess_rate_basis_points: 0, income_account_code: "4000", expense_account_code: "5000", active: true
    )
    load_accounts
  end

  def create
    @item = Items::Manage.create!(
      tenant: Current.tenant, attributes: normalized_item_params, actor: Current.user
    )
    redirect_to items_path(tenant_route_options), notice: "#{@item.code} · #{@item.name} added."
  rescue ActiveRecord::RecordInvalid, ArgumentError => e
    @item ||= item_scope.new(item_params)
    load_accounts
    flash.now[:alert] = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
    render :new, status: :unprocessable_entity
  end

  def edit
    load_accounts
  end

  def update
    Items::Manage.update!(item: @item, attributes: normalized_item_params, actor: Current.user)
    redirect_to items_path(tenant_route_options), notice: "#{@item.code} · #{@item.name} updated."
  rescue ActiveRecord::RecordInvalid, ArgumentError => e
    @item.assign_attributes(item_params) unless e.respond_to?(:record)
    load_accounts
    flash.now[:alert] = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
    render :edit, status: :unprocessable_entity
  end

  def deactivate
    change_active!(false)
  end

  def reactivate
    change_active!(true)
  end

  private

  def item_scope
    Item.where(tenant_id: Current.tenant.id)
  end

  def set_item
    @item = item_scope.find(params[:id])
  end

  def load_accounts
    @income_accounts = Account.active.where(tenant_id: Current.tenant.id, account_type: "income").in_code_order
    @expense_accounts = Account.active.where(tenant_id: Current.tenant.id, account_type: "expense").in_code_order
  end

  def change_active!(active)
    Items::Manage.update!(item: @item, attributes: { active: active }, actor: Current.user)
    label = active ? "reactivated" : "deactivated for new documents"
    redirect_to items_path(tenant_route_options), notice: "#{@item.code} #{label}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to edit_item_path(@item, tenant_route_options), alert: e.record.errors.full_messages.to_sentence
  end

  def normalized_item_params
    item_params.to_h.merge(
      tax_rate_basis_points: percentage_to_basis_points(item_params[:tax_rate]),
      cess_rate_basis_points: percentage_to_basis_points(item_params[:cess_rate])
    ).except("tax_rate", "cess_rate")
  end

  def percentage_to_basis_points(value)
    decimal = BigDecimal(value.to_s)
    basis_points = decimal * 100
    raise ArgumentError, "Tax rates may have no more than two decimal places" unless basis_points.frac.zero?

    basis_points.to_i
  rescue ArgumentError
    raise ArgumentError, "Tax rates must be valid percentages with no more than two decimal places"
  end

  def item_params
    params.require(:item).permit(
      :code, :name, :item_type, :description, :hsn_sac_code, :unit_of_measure,
      :tax_rate, :cess_rate, :income_account_code, :expense_account_code
    )
  end
end
