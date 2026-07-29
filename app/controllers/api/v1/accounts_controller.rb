# frozen_string_literal: true

module Api
  module V1
    class AccountsController < BaseController
      before_action -> { require_capability!("accounts.manage") }, only: :create

      def index
        render json: { accounts: scope.order(:code).map { |a| account_json(a) } }
      end

      def show
        render json: { account: account_json(scope.find(params[:id])) }
      end

      def create
        a = scope.create!(params.permit(:code, :name, :account_type).merge(tenant_id: Current.tenant.id))
        render json: { account: account_json(a) }, status: :created
      end

      private

      def scope
        Account.where(tenant_id: Current.tenant.id)
      end

      def account_json(a)
        { id: a.id, code: a.code, name: a.name, account_type: a.account_type }
      end
    end
  end
end
