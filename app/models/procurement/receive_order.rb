# frozen_string_literal: true

module Procurement
  module ReceiveOrder
    module_function

    def call(order:, actor:, attributes:, lines:)
      input = normalize!(order, attributes, lines)
      authorize!(order, actor)

      PurchaseOrder.transaction do
        LedgerEvent.acquire_tenant_lock!(order.tenant_id)
        existing = GoodsReceipt.find_by(
          tenant_id: order.tenant_id, idempotency_key: input.fetch(:idempotency_key)
        )
        return assert_same!(existing, input) if existing

        order.lock!
        raise InvalidProcurement, "purchase order is not open for receipt" unless order.receivable?
        receipt = GoodsReceipt.create!(
          tenant_id: order.tenant_id, purchase_order: order, created_by: actor,
          receipt_number: "GRN/#{order.order_number.delete_prefix('PO/')}/#{order.goods_receipts.count + 1}",
          idempotency_key: input.fetch(:idempotency_key), request_sha256: input.fetch(:request_sha256),
          received_on: input.fetch(:received_on), external_reference: input[:external_reference]
        )
        input.fetch(:lines).each do |line_id, quantity|
          order_line = order.purchase_order_lines.lock.find(line_id)
          raise InvalidProcurement, "receipt quantity exceeds the open purchase-order quantity" if
            quantity > order_line.open_quantity
          inventory_transaction = receive_inventory!(receipt, order_line, quantity, actor)
          receipt.goods_receipt_lines.create!(
            tenant_id: order.tenant_id, purchase_order_line: order_line,
            inventory_transaction: inventory_transaction, received_quantity: quantity
          )
          order_line.update!(received_quantity: order_line.received_quantity + quantity)
        end
        refresh_status!(order)
        DomainEvents::Record.call(
          tenant_id: order.tenant_id, office_id: order.office_id, kind: "purchase_order.received",
          actor: "u:#{actor.id}", actor_user_id: actor.id, ref: order.order_number,
          payload: {
            "purchaseOrderId" => order.id, "orderNumber" => order.order_number,
            "goodsReceiptId" => receipt.id, "receiptNumber" => receipt.receipt_number,
            "receivedOn" => receipt.received_on.to_s,
            "lines" => receipt.goods_receipt_lines.map do |line|
              { "purchaseOrderLineId" => line.purchase_order_line_id,
                "receivedQuantity" => line.received_quantity.to_s("F"),
                "inventoryTransactionId" => line.inventory_transaction_id }
            end
          }
        )
        receipt
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def normalize!(order, attributes, raw_lines)
      values = attributes.to_h.symbolize_keys
      normalized = Array(raw_lines).each_with_object({}) do |row, result|
        line_id = value(row, :purchase_order_line_id)
        next if line_id.blank? || value(row, :quantity).blank?

        quantity = Documents::DecimalInput.parse!(
          value(row, :quantity), label: "receipt quantity", scale: 6,
          error_class: InvalidProcurement
        )
        next unless quantity.positive?

        result[integer(line_id, "purchase-order line")] = quantity
      end
      raise InvalidProcurement, "receive at least one positive line quantity" if normalized.empty?
      input = {
        received_on: parse_date(values[:received_on]),
        external_reference: values[:external_reference].to_s.strip.presence,
        idempotency_key: values[:idempotency_key].to_s.strip,
        lines: normalized
      }
      raise InvalidProcurement, "idempotency key is required" if input[:idempotency_key].blank?
      input[:request_sha256] = Digest::SHA256.hexdigest(
        Folio::KhataHash.canonical_payload(request_payload(order, input))
      )
      input
    end

    def receive_inventory!(receipt, line, quantity, actor)
      return unless line.item_type == "good"

      Inventory::PostMovement.call(
        tenant: Tenant.find(receipt.tenant_id), actor: actor,
        attributes: {
          transaction_type: "receipt", posting_date: receipt.received_on,
          item_id: line.item_id, quantity: quantity,
          unit_cost: money_decimal(line.unit_price_minor, receipt.purchase_order.minor_unit_exponent),
          destination_warehouse_id: line.warehouse_id, offset_account_code: "2050",
          external_reference: receipt.external_reference,
          reason: "Goods receipt #{receipt.receipt_number}",
          idempotency_key: "procurement:#{receipt.idempotency_key}:#{line.id}"
        }
      )
    end

    def money_decimal(minor, exponent)
      (minor.to_d / (10**exponent)).to_s("F")
    end

    def refresh_status!(order)
      lines = order.purchase_order_lines.reload
      status = if lines.all? { |line| line.received_quantity == line.ordered_quantity }
        "received"
      else
        "partially_received"
      end
      order.update!(status: status)
    end

    def request_payload(order, input)
      {
        "purchaseOrderId" => order.id, "receivedOn" => input.fetch(:received_on).to_s,
        "externalReference" => input[:external_reference],
        "lines" => input.fetch(:lines).sort.to_h.transform_values { |quantity| quantity.to_s("F") }
      }.compact
    end

    def assert_same!(existing, input)
      payload = request_payload(existing.purchase_order, input)
      return existing if Digest::SHA256.hexdigest(Folio::KhataHash.canonical_payload(payload)) ==
        existing.request_sha256

      raise InvalidProcurement, "the idempotency key already belongs to another goods receipt"
    end

    def authorize!(order, actor)
      return if Authorization.permits?(
        user: actor, tenant_id: order.tenant_id, office_id: order.office_id,
        capability: "procurement.receive"
      )

      raise InvalidProcurement, "not permitted to receive purchase orders"
    end

    def parse_date(raw)
      return raw if raw.is_a?(Date)

      Date.iso8601(raw.to_s)
    rescue Date::Error
      raise InvalidProcurement, "receipt date must be a valid ISO date"
    end

    def integer(raw, label)
      Integer(raw, exception: false) || raise(InvalidProcurement, "choose a valid #{label}")
    end

    def value(hash, key)
      hash[key] || hash[key.to_s]
    end
  end
end
