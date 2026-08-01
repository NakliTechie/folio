# frozen_string_literal: true

module Consolidation
  module Manage
    module_function

    def ensure_group!(tenant:, actor:)
      authorize!(tenant, actor)
      group = ConsolidationGroup.find_or_create_by!(tenant_id: tenant.id, code: "GROUP") do |record|
        record.name = "#{tenant.name} Group"
        record.presentation_currency = tenant.functional_currency
        record.created_by = actor
      end
      Entity.where(tenant_id: tenant.id).find_each do |entity|
        add_member!(group: group, entity: entity, effective_from: Date.new(1900, 1, 1))
      end
      group
    end

    def create_entity!(tenant:, group:, actor:, attributes:)
      authorize!(tenant, actor)
      values = attributes.to_h.symbolize_keys
      code = values[:code].to_s.strip.upcase
      raise InvalidConsolidation, "entity code is required" if code.blank?
      primary = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      Entity.transaction do
        entity = Entity.create!(
          tenant_id: tenant.id, code: code, legal_name: values[:legal_name],
          functional_currency: group.presentation_currency,
          fiscal_year_variant: primary.fiscal_year_variant,
          jurisdiction_profile: primary.jurisdiction_profile
        )
        Office.create!(
          tenant_id: tenant.id, entity: entity, code: "#{code}-HO",
          name: values[:office_name].presence || "#{code} Head Office"
        )
        add_member!(
          group: group, entity: entity,
          effective_from: parse_date(values[:effective_from].presence || Date.new(1900, 1, 1))
        )
        entity
      end
    end

    def add_member!(group:, entity:, effective_from:)
      unless entity.functional_currency == group.presentation_currency
        raise InvalidConsolidation,
          "cross-currency consolidation is blocked until a group translation policy is approved"
      end
      ConsolidationGroupMember.find_or_create_by!(
        tenant_id: group.tenant_id, consolidation_group: group, entity: entity
      ) do |member|
        member.ownership_basis_points = 10_000
        member.effective_from = effective_from
      end
    end

    def authorize!(tenant, actor)
      return if Authorization.permits?(
        user: actor, tenant_id: tenant.id, capability: "consolidation.manage"
      )

      raise InvalidConsolidation, "not permitted to manage consolidation"
    end

    def parse_date(value)
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    rescue Date::Error
      raise InvalidConsolidation, "effective date must be a valid ISO date"
    end
  end
end
