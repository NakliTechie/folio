# frozen_string_literal: true

module Procurement
  module CloseOrder
    module_function

    def call(order:, actor:)
      authorize!(order, actor)
      PurchaseOrder.transaction do
        order.lock!
        unless %w[approved partially_received received].include?(order.status)
          raise InvalidProcurement, "only a released purchase order can be closed"
        end

        order.update!(status: "closed", closed_on: Tenant.find(order.tenant_id).business_date)
        DomainEvents::Record.call(
          tenant_id: order.tenant_id, office_id: order.office_id, kind: "purchase_order.closed",
          actor: "u:#{actor.id}", actor_user_id: actor.id, ref: order.order_number,
          payload: CreateOrder.snapshot(order).merge("closedOn" => order.closed_on.to_s)
        )
        order
      end
    end

    def authorize!(order, actor)
      return if Authorization.permits?(
        user: actor, tenant_id: order.tenant_id, office_id: order.office_id,
        capability: "procurement.approve"
      )

      raise InvalidProcurement, "not permitted to close purchase orders"
    end
  end
end
