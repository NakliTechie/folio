# frozen_string_literal: true

module Inventory
  module ManageWarehouse
    module_function

    def create!(tenant:, actor:, attributes:)
      entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      office = Office.find_by!(tenant_id: tenant.id, entity_id: entity.id, code: "PRIMARY")
      Warehouse.transaction do
        warehouse = Warehouse.create!(
          attributes.merge(tenant_id: tenant.id, entity: entity, office: office)
        )
        MasterData::Audit.append!(
          tenant_id: tenant.id, actor: actor, action: "warehouse.created", ref: warehouse.code,
          subject: {
            "id" => warehouse.id, "code" => warehouse.code, "name" => warehouse.name,
            "warehouseType" => warehouse.warehouse_type
          },
          changes: warehouse.attributes.slice("code", "name", "warehouse_type", "active")
            .transform_values { |value| { "to" => value } }
        )
        warehouse
      end
    end
  end
end
