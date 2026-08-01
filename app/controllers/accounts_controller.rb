# frozen_string_literal: true

class AccountsController < BrowserController
  before_action -> { require_capability!("accounts.read") }, only: :index
  before_action -> { require_capability!("accounts.manage") },
    only: %i[new create edit update deactivate reactivate]
  before_action :set_account, only: %i[edit update deactivate reactivate]

  def index
    @accounts = account_scope.in_code_order
  end

  def new
    @account = account_scope.new
  end

  def create
    @account = Accounts::Manage.create!(
      tenant: Current.tenant, attributes: account_params.to_h, actor: Current.user
    )
    redirect_to accounts_path(tenant_route_options), notice: "#{@account.code} · #{@account.name} added."
  rescue ActiveRecord::RecordInvalid => e
    @account ||= e.record
    flash.now[:alert] = e.record.errors.full_messages.to_sentence
    render :new, status: :unprocessable_entity
  end

  def edit; end

  def update
    Accounts::Manage.update!(account: @account, attributes: account_params.to_h, actor: Current.user)
    redirect_to accounts_path(tenant_route_options), notice: "#{@account.code} · #{@account.name} updated."
  rescue ActiveRecord::RecordInvalid => e
    @account = e.record
    flash.now[:alert] = e.record.errors.full_messages.to_sentence
    render :edit, status: :unprocessable_entity
  end

  def deactivate
    Accounts::Manage.update!(account: @account, attributes: { active: false }, actor: Current.user)
    redirect_to accounts_path(tenant_route_options), notice: "#{@account.code} deactivated for future entries."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to edit_account_path(@account, tenant_route_options),
      alert: e.record.errors.full_messages.to_sentence
  end

  def reactivate
    Accounts::Manage.update!(account: @account, attributes: { active: true }, actor: Current.user)
    redirect_to accounts_path(tenant_route_options), notice: "#{@account.code} reactivated."
  end

  private

  def account_scope
    Account.where(tenant_id: Current.tenant.id)
  end

  def set_account
    @account = account_scope.find(params[:id])
  end

  def account_params
    params.require(:account).permit(:code, :name, :account_type, :monetary)
  end
end
