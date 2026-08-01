# frozen_string_literal: true

module Controlling
  module Manage
    module_function

    def create_segment!(tenant:, actor:, attributes:)
      create_audited!(ControllingSegment, tenant, actor, "segment", attributes, %i[code name])
    end

    def create_profit_center!(tenant:, actor:, attributes:)
      entity = primary_entity(tenant)
      values = attributes.to_h.symbolize_keys.slice(:code, :name, :valid_from, :valid_to)
      segment = ControllingSegment.active.where(tenant_id: tenant.id)
        .find(attributes[:controlling_segment_id] || attributes["controlling_segment_id"])
      create_audited!(ProfitCenter, tenant, actor, "profit_center",
        values.merge(entity: entity, controlling_segment: segment), values.keys + %i[entity controlling_segment])
    end

    def create_cost_center!(tenant:, actor:, attributes:)
      entity = primary_entity(tenant)
      values = attributes.to_h.symbolize_keys.slice(:code, :name, :valid_from, :valid_to)
      profit = ProfitCenter.active.where(tenant_id: tenant.id, entity_id: entity.id)
        .find(attributes[:profit_center_id] || attributes["profit_center_id"])
      create_audited!(CostCenter, tenant, actor, "cost_center",
        values.merge(entity: entity, profit_center: profit), values.keys + %i[entity profit_center])
    end

    def create_plan_line!(tenant:, actor:, attributes:)
      values = attributes.to_h.symbolize_keys
      center = CostCenter.active.where(tenant_id: tenant.id).find(values.fetch(:cost_center_id))
      exponent = CurrencyProfile.exponent_for!(tenant.functional_currency)
      amount = Documents::DecimalInput.parse!(
        values.fetch(:amount), label: "plan amount", scale: exponent,
        error_class: InvalidControl
      )
      ControllingPlanLine.create!(
        tenant_id: tenant.id, cost_center: center, created_by: actor,
        account_code: values.fetch(:account_code), version: values[:version].presence || "BUDGET",
        fiscal_year: values.fetch(:fiscal_year), period_no: values.fetch(:period_no),
        currency: tenant.functional_currency, amount_minor: (amount * (10**exponent)).to_i
      )
    end

    def create_cycle!(tenant:, actor:, attributes:, receivers:)
      values = attributes.to_h.symbolize_keys
      entity = primary_entity(tenant)
      office = Office.find_by!(tenant_id: tenant.id, entity_id: entity.id, code: "PRIMARY")
      sender = CostCenter.active.where(tenant_id: tenant.id, entity_id: entity.id)
        .find(values.fetch(:sender_cost_center_id))
      normalized = normalize_receivers!(tenant, entity, sender, receivers)
      AllocationCycle.transaction do
        cycle = AllocationCycle.create!(
          tenant_id: tenant.id, entity: entity, office: office, sender_cost_center: sender,
          code: values.fetch(:code), name: values.fetch(:name), allocation_type: "distribution",
          source_account_code: values.fetch(:source_account_code), valid_from: values.fetch(:valid_from),
          valid_to: values[:valid_to].presence
        )
        normalized.each do |receiver|
          cycle.allocation_receivers.create!(
            tenant_id: tenant.id, cost_center: receiver.fetch(:cost_center),
            weight_basis_points: receiver.fetch(:weight_basis_points)
          )
        end
        MasterData::Audit.append!(
          tenant_id: tenant.id, actor: actor, action: "allocation_cycle.created", ref: cycle.code,
          subject: { "id" => cycle.id, "code" => cycle.code, "name" => cycle.name },
          changes: {
            "senderCostCenterId" => { "to" => sender.id },
            "sourceAccountCode" => { "to" => cycle.source_account_code },
            "receivers" => { "to" => normalized.map { |row|
              { "costCenterId" => row.fetch(:cost_center).id,
                "weightBasisPoints" => row.fetch(:weight_basis_points) }
            } }
          }
        )
        cycle
      end
    end

    def normalize_receivers!(tenant, entity, sender, receivers)
      rows = Array(receivers).filter_map do |row|
        values = row.to_h.symbolize_keys
        next if values[:cost_center_id].blank?

        center = CostCenter.active.where(tenant_id: tenant.id, entity_id: entity.id)
          .find(values.fetch(:cost_center_id))
        raise InvalidControl, "sender cannot also be an allocation receiver" if center == sender

        { cost_center: center, weight_basis_points: strict_weight(values.fetch(:weight_basis_points)) }
      end
      raise InvalidControl, "add at least one allocation receiver" if rows.empty?
      raise InvalidControl, "allocation receiver weights must total exactly 100%" unless
        rows.sum { |row| row.fetch(:weight_basis_points) } == 10_000

      rows
    end

    def strict_weight(value)
      return value if value.is_a?(Integer)
      return Integer(value, 10) if value.is_a?(String) && value.match?(/\A\d+\z/)

      raise InvalidControl, "allocation weights must be whole basis points"
    rescue ArgumentError, TypeError
      raise InvalidControl, "allocation weights must be whole basis points"
    end

    def create_audited!(klass, tenant, actor, prefix, attributes, fields)
      klass.transaction do
        record = klass.create!(attributes.to_h.symbolize_keys.merge(tenant_id: tenant.id))
        MasterData::Audit.append!(
          tenant_id: tenant.id, actor: actor, action: "#{prefix}.created", ref: record.code,
          subject: { "id" => record.id, "code" => record.code, "name" => record.name },
          changes: record.attributes.slice(*fields.map(&:to_s)).transform_values { |value| { "to" => value } }
        )
        record
      end
    end

    def primary_entity(tenant)
      Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
    end
  end
end
