# frozen_string_literal: true

class AccountsController < BrowserController
  before_action -> { require_capability!("accounts.manage") }, only: %i[new create]

  def index
    @accounts = account_scope.order(:code)
  end

  def new
    @account = account_scope.new
  end

  def create
    @account = account_scope.create!(account_params.merge(tenant_id: Current.tenant.id))
    redirect_to accounts_path(tenant_route_options), notice: "#{@account.code} · #{@account.name} added."
  rescue ActiveRecord::RecordInvalid => e
    @account ||= e.record
    flash.now[:alert] = e.record.errors.full_messages.to_sentence
    render :new, status: :unprocessable_entity
  end

  private

  def account_scope
    Account.where(tenant_id: Current.tenant.id)
  end

  def account_params
    params.require(:account).permit(:code, :name, :account_type)
  end
end
