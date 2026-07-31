# frozen_string_literal: true

module Api
  module V1
    class ItemsController < BaseController
      before_action -> { require_capability!("masters.manage") }, only: %i[create update]
      before_action :set_item, only: %i[show update]

      def index
        render json: { items: scope.order(:code).map { |item| item_json(item) } }
      end

      def show
        render json: { item: item_json(@item) }
      end

      def create
        item = Items::Manage.create!(
          tenant: Current.tenant, attributes: item_params.to_h, actor: current_user
        )
        render json: { item: item_json(item) }, status: :created
      end

      def update
        Items::Manage.update!(item: @item, attributes: item_params.to_h, actor: current_user)
        render json: { item: item_json(@item.reload) }
      end

      private

      def scope
        Item.where(tenant_id: Current.tenant.id)
      end

      def set_item
        @item = scope.find(params[:id])
      end

      def item_params
        params.permit(
          :code, :name, :item_type, :description, :hsn_sac_code, :unit_of_measure,
          :tax_rate_basis_points, :cess_rate_basis_points,
          :income_account_code, :expense_account_code, :active
        )
      end

      def item_json(item)
        {
          id: item.id, code: item.code, name: item.name, item_type: item.item_type,
          description: item.description, hsn_sac_code: item.hsn_sac_code,
          unit_of_measure: item.unit_of_measure,
          tax_rate_basis_points: item.tax_rate_basis_points,
          cess_rate_basis_points: item.cess_rate_basis_points,
          income_account_code: item.income_account_code,
          expense_account_code: item.expense_account_code,
          active: item.active
        }
      end
    end
  end
end
