# frozen_string_literal: true

module Api
  module V1
    class AccountsController < BaseController
      before_action -> { require_capability!("accounts.manage") }, only: %i[create update]
      before_action :set_account, only: %i[show update]

      def index
        render json: { accounts: scope.in_code_order.map { |a| account_json(a) } }
      end

      def show
        render json: { account: account_json(@account) }
      end

      def create
        a = Accounts::Manage.create!(tenant: Current.tenant, attributes: account_params.to_h, actor: current_user)
        render json: { account: account_json(a) }, status: :created
      end

      def update
        Accounts::Manage.update!(account: @account, attributes: account_params.to_h, actor: current_user)
        render json: { account: account_json(@account) }
      end

      private

      def scope
        Account.where(tenant_id: Current.tenant.id)
      end

      def set_account
        @account = scope.find(params[:id])
      end

      def account_params
        params.permit(:code, :name, :account_type, :active)
      end

      def account_json(a)
        { id: a.id, code: a.code, name: a.name, account_type: a.account_type,
          active: a.active, code_locked: a.code_locked?, posted: a.posted? }
      end
    end
  end
end
