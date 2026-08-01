# frozen_string_literal: true

module Inventory
  module PostMovement
    TYPES = InventoryTransaction::TYPES.freeze
    INBOUND = %w[receipt adjustment_in].freeze
    OUTBOUND = %w[issue adjustment_out].freeze

    module_function

    def call(tenant:, actor:, attributes:)
      input = normalize!(tenant, attributes)
      entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      office = Office.find_by!(tenant_id: tenant.id, entity_id: entity.id, code: "PRIMARY")
      authorize!(tenant, office, actor)

      InventoryTransaction.transaction do
        LedgerEvent.acquire_tenant_lock!(tenant.id)
        existing = InventoryTransaction.find_by(
          tenant_id: tenant.id, idempotency_key: input.fetch(:idempotency_key)
        )
        return assert_same_request!(existing, input) if existing

        item = Item.active.where(tenant_id: tenant.id, item_type: "good").find(input.fetch(:item_id))
        source = warehouse(tenant, input[:source_warehouse_id])
        destination = warehouse(tenant, input[:destination_warehouse_id])
        assert_shape!(input.fetch(:transaction_type), source, destination)
        offset = offset_account(tenant, input.fetch(:transaction_type), input[:offset_account_code], item)
        ledger = Ledger.find_by!(tenant_id: tenant.id, code: "PRIMARY")
        assert_inventory_period!(tenant, entity, office, ledger, actor, input.fetch(:posting_date))

        balances = [ source, destination ].compact.uniq.index_with do |location|
          StockBalance.find_or_create_by!(
            tenant_id: tenant.id, item_id: item.id, warehouse_id: location.id
          )
        end
        balances.values.sort_by(&:id).each(&:lock!)
        assert_chronological!(
          tenant: tenant, item: item, warehouses: balances.keys,
          posting_date: input.fetch(:posting_date)
        )

        value = movement_value(input, source && balances.fetch(source), tenant.functional_currency)
        entry = post_entry!(
          tenant: tenant, entity: entity, office: office, ledger: ledger, actor: actor,
          item: item, source: source, destination: destination, offset: offset,
          input: input, value: value
        )
        event = LedgerEvent.find(entry.ledger_event_id)
        transaction = InventoryTransaction.create!(
          tenant_id: tenant.id, entity: entity, office: office, created_by: actor,
          item: item, source_warehouse: source, destination_warehouse: destination,
          ledger_event: event, idempotency_key: input.fetch(:idempotency_key),
          request_sha256: input.fetch(:request_sha256),
          transaction_type: input.fetch(:transaction_type), posting_date: input.fetch(:posting_date),
          quantity: input.fetch(:quantity), unit_cost_minor: input[:unit_cost_minor],
          total_value_minor: value, offset_account_code: offset&.code,
          external_reference: input[:external_reference], reason: input.fetch(:reason)
        )
        apply_balances!(transaction, balances, source, destination, input.fetch(:quantity), value)
        transaction
      end
    rescue ActiveRecord::RecordNotFound
      raise InvalidMovement, "choose an active inventory item and warehouse in this company"
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def normalize!(tenant, attributes)
      type = value(attributes, :transaction_type).to_s
      raise InvalidMovement, "choose a valid inventory movement type" unless TYPES.include?(type)
      date = parse_date(value(attributes, :posting_date))
      quantity = Documents::DecimalInput.parse!(
        value(attributes, :quantity), label: "quantity", scale: 6, error_class: InvalidMovement
      )
      raise InvalidMovement, "quantity must be positive" unless quantity.positive?
      cost = if INBOUND.include?(type)
        exponent = CurrencyProfile.exponent_for!(tenant.functional_currency)
        amount = Documents::DecimalInput.parse!(
          value(attributes, :unit_cost), label: "unit cost", scale: exponent,
          error_class: InvalidMovement
        )
        minor = (amount * (10**exponent)).to_i
        raise InvalidMovement, "unit cost must be positive" unless minor.positive?
        minor
      end
      key = value(attributes, :idempotency_key).to_s.strip
      reason = value(attributes, :reason).to_s.strip
      raise InvalidMovement, "idempotency key is required" if key.blank?
      raise InvalidMovement, "reason is required" if reason.blank?

      normalized = {
        transaction_type: type, posting_date: date, quantity: quantity,
        unit_cost_minor: cost, item_id: integer(value(attributes, :item_id), "item"),
        source_warehouse_id: optional_integer(value(attributes, :source_warehouse_id), "source warehouse"),
        destination_warehouse_id: optional_integer(
          value(attributes, :destination_warehouse_id), "destination warehouse"
        ),
        offset_account_code: value(attributes, :offset_account_code).to_s.strip.presence,
        external_reference: value(attributes, :external_reference).to_s.strip.presence,
        reason: reason, idempotency_key: key
      }
      normalized[:request_sha256] = Digest::SHA256.hexdigest(
        Folio::KhataHash.canonical_payload(normalized.except(:request_sha256).transform_values(&:to_s))
      )
      normalized
    end

    def movement_value(input, source_balance, currency)
      if INBOUND.include?(input.fetch(:transaction_type))
        (input.fetch(:quantity) * input.fetch(:unit_cost_minor))
          .round(0, BigDecimal::ROUND_HALF_UP).to_i.tap do |value|
            raise InvalidMovement, "movement value rounds to zero #{currency}" unless value.positive?
          end
      else
        quantity = input.fetch(:quantity)
        unless source_balance && source_balance.quantity >= quantity
          available = source_balance&.quantity || 0
          raise InvalidMovement, "insufficient stock: #{available.to_d.to_s('F')} available"
        end
        return source_balance.inventory_value_minor if source_balance.quantity == quantity

        (source_balance.inventory_value_minor.to_d * quantity / source_balance.quantity)
          .round(0, BigDecimal::ROUND_HALF_UP).to_i.tap do |value|
            raise InvalidMovement, "moving-average value rounds to zero" unless value.positive?
          end
      end
    end

    def assert_chronological!(tenant:, item:, warehouses:, posting_date:)
      latest = InventoryTransaction.joins(:inventory_movements).where(
        inventory_transactions: { tenant_id: tenant.id, item_id: item.id },
        inventory_movements: { warehouse_id: warehouses.map(&:id) }
      ).maximum(:posting_date)
      return unless latest && latest > posting_date

      raise InvalidMovement,
        "inventory movements must be posted chronologically; latest affected movement is #{latest}"
    end

    def post_entry!(tenant:, entity:, office:, ledger:, actor:, item:, source:, destination:, offset:, input:, value:)
      exponent = CurrencyProfile.exponent_for!(tenant.functional_currency)
      extra = {
        "inventoryIdempotencyKey" => input.fetch(:idempotency_key),
        "externalReference" => input[:external_reference], "reason" => input.fetch(:reason),
        "itemRevision" => item.revision, "valuationMethod" => item.valuation_method
      }.compact
      lines = posting_lines(
        item: item, source: source, destination: destination, offset: offset,
        type: input.fetch(:transaction_type), quantity: input.fetch(:quantity), value: value,
        ledger: ledger, entity: entity, office: office, currency: tenant.functional_currency,
        exponent: exponent, extra: extra
      )
      Posting::PostEntry.post!(
        tenant_id: tenant.id, entity_id: entity.id, office_id: office.id,
        actor: "u:#{actor.id}", actor_user_id: actor.id, origin: "folio.inventory",
        document_date: input.fetch(:posting_date), posting_date: input.fetch(:posting_date),
        entered_at: Time.current,
        fiscal_year: Documents.fiscal_year(
          input.fetch(:posting_date), variant: entity.fiscal_year_variant
        ),
        period_no: Documents.period_no(input.fetch(:posting_date), variant: entity.fiscal_year_variant),
        authority: Authorization.authority_for(
          user: actor, tenant_id: tenant.id, office_id: office.id
        ),
        capabilities: capabilities_for(tenant, office, actor), lines: lines
      )
    end

    def posting_lines(item:, source:, destination:, offset:, type:, quantity:, value:,
                      ledger:, entity:, office:, currency:, exponent:, extra:)
      amount = ->(minor) { [ { slot_role: "transaction", currency: currency,
        minor_unit_exponent: exponent, amount_minor: minor } ] }
      stock = lambda do |number, warehouse, signed_quantity, signed_value, movement_type|
        {
          line_no: number, account_code: item.inventory_account_code, ledger_id: ledger.id,
          entity_id: entity.id, office_id: office.id, item_id: item.id, warehouse_id: warehouse.id,
          quantity: signed_quantity, uom: item.unit_of_measure, movement_type: movement_type,
          valuation_view: item.valuation_method, extra: extra, amounts: amount.call(signed_value)
        }
      end
      plain = lambda do |number, signed_value|
        {
          line_no: number, account_code: offset.code, ledger_id: ledger.id,
          entity_id: entity.id, office_id: office.id, extra: extra,
          amounts: amount.call(signed_value)
        }
      end

      if INBOUND.include?(type)
        [ stock.call(1, destination, quantity, value, type), plain.call(2, -value) ]
      elsif OUTBOUND.include?(type)
        [ plain.call(1, value), stock.call(2, source, -quantity, -value, type) ]
      else
        [
          stock.call(1, destination, quantity, value, "transfer_in"),
          stock.call(2, source, -quantity, -value, "transfer_out")
        ]
      end
    end

    def apply_balances!(transaction, balances, source, destination, quantity, value)
      changes = if transaction.transaction_type == "transfer"
        [ [ destination, quantity, value, 1 ], [ source, -quantity, -value, 2 ] ]
      elsif INBOUND.include?(transaction.transaction_type)
        [ [ destination, quantity, value, 1 ] ]
      else
        [ [ source, -quantity, -value, 2 ] ]
      end
      changes.each do |warehouse, quantity_change, value_change, line_no|
        balance = balances.fetch(warehouse)
        balance.quantity += quantity_change
        balance.inventory_value_minor += value_change
        balance.inventory_value_minor = 0 if balance.quantity.zero?
        balance.save!
        transaction.inventory_movements.create!(
          tenant_id: transaction.tenant_id, item: transaction.item, warehouse: warehouse,
          ledger_event: transaction.ledger_event, entry_line_no: line_no,
          quantity: quantity_change, inventory_value_minor: value_change,
          balance_quantity_after: balance.quantity,
          balance_value_after_minor: balance.inventory_value_minor
        )
      end
    end

    def assert_inventory_period!(tenant, entity, office, ledger, actor, date)
      fiscal_year = Documents.fiscal_year(date, variant: entity.fiscal_year_variant)
      period = Documents.period_no(date, variant: entity.fiscal_year_variant)
      state, capability = PeriodControl.resolve(
        tenant_id: tenant.id, entity_id: entity.id, ledger_id: ledger.id,
        account_class: "ALL", fiscal_year: fiscal_year, period_no: period, domain: "inventory"
      )
      raise Posting::PeriodClosedError, "inventory period #{fiscal_year}/#{period} is closed" if state == "closed"
      return unless state == "restricted"
      return if capability && Authorization.permits?(
        user: actor, tenant_id: tenant.id, capability: capability, office_id: office.id
      )

      raise Posting::PeriodRestrictedError,
        "inventory period #{fiscal_year}/#{period} is restricted; capability '#{capability}' required"
    end

    def offset_account(tenant, type, code, item)
      return if type == "transfer"

      account = Account.active.find_by(tenant_id: tenant.id, code: code)
      unless account && account.code != item.inventory_account_code
        raise InvalidMovement, "choose an active offset account different from the inventory account"
      end
      account
    end

    def warehouse(tenant, id)
      return if id.blank?

      Warehouse.active.where(tenant_id: tenant.id).find(id)
    end

    def assert_shape!(type, source, destination)
      valid = if INBOUND.include?(type)
        source.nil? && destination.present?
      elsif OUTBOUND.include?(type)
        source.present? && destination.nil?
      else
        source.present? && destination.present? && source != destination
      end
      raise InvalidMovement, "choose warehouses appropriate for the movement type" unless valid
    end

    def assert_same_request!(existing, input)
      return existing if existing.request_sha256 == input.fetch(:request_sha256)

      raise InvalidMovement, "the idempotency key already belongs to another inventory movement"
    end

    def authorize!(tenant, office, actor)
      return if Authorization.permits?(
        user: actor, tenant_id: tenant.id, office_id: office.id, capability: "inventory.post"
      )

      raise InvalidMovement, "not permitted to post inventory movements"
    end

    def capabilities_for(tenant, office, actor)
      Authorization.role_for(user: actor, tenant_id: tenant.id, office_id: office.id)
        &.role_template&.role_permissions&.pluck(:capability) || []
    end

    def parse_date(value)
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    rescue Date::Error
      raise InvalidMovement, "posting date must be a valid ISO date"
    end

    def integer(value, label)
      return value if value.is_a?(Integer)

      Integer(value, 10)
    rescue ArgumentError, TypeError
      raise InvalidMovement, "choose a valid #{label}"
    end

    def optional_integer(value, label)
      value.present? ? integer(value, label) : nil
    end

    def value(attributes, key)
      attributes[key] || attributes[key.to_s]
    end
  end
end
