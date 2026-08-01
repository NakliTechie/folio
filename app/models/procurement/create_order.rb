# frozen_string_literal: true

module Procurement
  module CreateOrder
    module_function

    def call(tenant:, actor:, attributes:, lines:)
      values = attributes.to_h.symbolize_keys
      order_date = parse_date(values[:order_date], "order date")
      entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      office = Office.find_by!(tenant_id: tenant.id, entity_id: entity.id, code: "PRIMARY")
      vendor = VendorProfile.includes(:party).where(tenant_id: tenant.id).find(values.fetch(:vendor_profile_id))
      raise InvalidProcurement, "vendor is not approved for purchasing" unless vendor.orderable?
      authorize!(tenant, office, actor)
      normalized = normalize_lines!(tenant, lines)
      subtotal = normalized.sum { |line| line.fetch(:line_total_minor) }

      PurchaseOrder.transaction do
        order_number, fiscal_year = allocate_number!(tenant, entity, office, order_date)
        order = PurchaseOrder.create!(
          tenant_id: tenant.id, entity: entity, office: office, vendor_profile: vendor,
          created_by: actor, order_number: order_number, fiscal_year: fiscal_year,
          status: "draft", order_date: order_date,
          expected_on: parse_optional_date(values[:expected_on], "expected date"),
          currency: tenant.functional_currency,
          minor_unit_exponent: CurrencyProfile.exponent_for!(tenant.functional_currency),
          subtotal_minor: subtotal, description: values[:description]
        )
        normalized.each_with_index do |line, index|
          order.purchase_order_lines.create!(line.merge(
            tenant_id: tenant.id, line_no: index + 1
          ))
        end
        DomainEvents::Record.call(
          tenant_id: tenant.id, office_id: office.id, kind: "purchase_order.raised",
          actor: "u:#{actor.id}", actor_user_id: actor.id, ref: order.order_number,
          payload: snapshot(order)
        )
        order
      end
    end

    def normalize_lines!(tenant, raw_lines)
      rows = Array(raw_lines).reject { |line| value(line, :item_id).blank? }
      raise InvalidProcurement, "add at least one purchase-order line" if rows.empty?
      seen = {}
      exponent = CurrencyProfile.exponent_for!(tenant.functional_currency)
      rows.map do |row|
        item = Item.active.where(tenant_id: tenant.id).find(value(row, :item_id))
        raise InvalidProcurement, "each item may appear only once on a purchase order" if seen[item.id]
        seen[item.id] = true
        quantity = Documents::DecimalInput.parse!(
          value(row, :quantity), label: "quantity for #{item.code}", scale: 6,
          error_class: InvalidProcurement
        )
        raise InvalidProcurement, "quantity for #{item.code} must be positive" unless quantity.positive?
        price = Documents::DecimalInput.parse!(
          value(row, :unit_price), label: "unit price for #{item.code}", scale: exponent,
          minimum: 0, error_class: InvalidProcurement
        )
        unit_price_minor = (price * (10**exponent)).to_i
        total = (quantity * unit_price_minor).round(0, BigDecimal::ROUND_HALF_UP).to_i
        raise InvalidProcurement, "line value for #{item.code} must be positive" unless total.positive?
        warehouse = if item.good?
          Warehouse.active.where(tenant_id: tenant.id).find(value(row, :warehouse_id))
        end
        {
          item: item, warehouse: warehouse, description: item.name,
          ordered_quantity: quantity, unit_price_minor: unit_price_minor,
          line_total_minor: total,
          account_code: item.good? ? item.inventory_account_code : item.expense_account_code,
          item_type: item.item_type,
          item_snapshot: {
            "id" => item.id, "code" => item.code, "name" => item.name,
            "itemType" => item.item_type, "revision" => item.revision,
            "unitOfMeasure" => item.unit_of_measure,
            "accountCode" => item.good? ? item.inventory_account_code : item.expense_account_code
          }.compact
        }
      end
    rescue ActiveRecord::RecordNotFound
      raise InvalidProcurement, "choose active items and warehouses in this company"
    end

    def allocate_number!(tenant, entity, office, date)
      fiscal_year = Documents.fiscal_year(date, variant: entity.fiscal_year_variant)
      key = { tenant_id: tenant.id, entity_id: entity.id, office_id: office.id, fiscal_year: fiscal_year }
      begin
        PurchaseOrderNumberRange.find_or_create_by!(key)
      rescue ActiveRecord::RecordNotUnique
        retry
      end
      row = PurchaseOrderNumberRange.lock.find_by!(key)
      value = row.next_value
      row.update!(next_value: value + 1)
      [ "PO/#{fiscal_year}-#{(fiscal_year + 1) % 100}/#{value.to_s.rjust(5, '0')}", fiscal_year ]
    end

    def snapshot(order)
      {
        "purchaseOrderId" => order.id, "orderNumber" => order.order_number,
        "status" => order.status, "orderDate" => order.order_date.to_s,
        "vendorProfileId" => order.vendor_profile_id, "partyId" => order.vendor.id,
        "partyNumber" => order.vendor.party_number, "currency" => order.currency,
        "subtotalMinor" => order.subtotal_minor,
        "lines" => order.purchase_order_lines.order(:line_no).map do |line|
          {
            "lineId" => line.id, "lineNo" => line.line_no,
            "itemId" => line.item_id, "item" => line.item_snapshot,
            "orderedQuantity" => line.ordered_quantity.to_s("F"),
            "unitPriceMinor" => line.unit_price_minor,
            "lineTotalMinor" => line.line_total_minor
          }
        end
      }
    end

    def authorize!(tenant, office, actor)
      return if Authorization.permits?(
        user: actor, tenant_id: tenant.id, office_id: office.id, capability: "procurement.manage"
      )

      raise InvalidProcurement, "not permitted to create purchase orders"
    end

    def parse_date(raw, label)
      return raw if raw.is_a?(Date)

      Date.iso8601(raw.to_s)
    rescue Date::Error
      raise InvalidProcurement, "#{label} must be a valid ISO date"
    end

    def parse_optional_date(raw, label)
      raw.present? ? parse_date(raw, label) : nil
    end

    def value(hash, key)
      hash[key] || hash[key.to_s]
    end
  end
end
