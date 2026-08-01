# frozen_string_literal: true

module Inventory
  module RebuildBalances
    module_function

    def call(tenant_id:)
      StockBalance.transaction do
        LedgerEvent.acquire_tenant_lock!(tenant_id)
        StockBalance.where(tenant_id: tenant_id).delete_all
        InventoryMovement.where(tenant_id: tenant_id)
          .group(:item_id, :warehouse_id)
          .pluck(:item_id, :warehouse_id, Arel.sql("SUM(quantity)"),
            Arel.sql("SUM(inventory_value_minor)"))
          .each do |item_id, warehouse_id, quantity, value|
            StockBalance.create!(
              tenant_id: tenant_id, item_id: item_id, warehouse_id: warehouse_id,
              quantity: quantity, inventory_value_minor: Integer(value)
            )
          end
      end
    end
  end
end
