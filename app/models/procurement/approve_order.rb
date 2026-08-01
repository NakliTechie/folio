# frozen_string_literal: true

module Procurement
  module ApproveOrder
    module_function

    def call(order:, actor:)
      PurchaseOrder.transaction do
        order.lock!
        raise InvalidProcurement, "only a draft purchase order can be approved" unless order.status == "draft"
        raise InvalidProcurement, "purchase-order creator cannot approve their own order" if order.created_by_id == actor.id
        raise InvalidProcurement, "vendor is no longer approved for purchasing" unless order.vendor_profile.orderable?
        unless Authorization.permits?(
          user: actor, tenant_id: order.tenant_id, office_id: order.office_id,
          capability: "procurement.approve", amount_minor: order.subtotal_minor
        )
          raise InvalidProcurement, "not permitted to approve this purchase order"
        end

        order.update!(status: "approved", approved_by: actor, approved_at: Time.current)
        DomainEvents::Record.call(
          tenant_id: order.tenant_id, office_id: order.office_id, kind: "purchase_order.approved",
          actor: "u:#{actor.id}", actor_user_id: actor.id, ref: order.order_number,
          payload: CreateOrder.snapshot(order).merge("approvedById" => actor.id)
        )
        order
      end
    end
  end
end
