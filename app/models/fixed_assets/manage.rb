# frozen_string_literal: true

module FixedAssets
  module Manage
    ATTRIBUTES = %i[
      asset_class_id asset_number component_number name description capitalization_date
      quantity unit_of_measure serial_number inventory_number manufacturer
    ].freeze

    module_function

    def create!(tenant:, actor:, attributes:, book_terms:, tax_terms:)
      values = attributes.to_h.symbolize_keys.slice(*ATTRIBUTES)
      entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      office = Office.find_by!(tenant_id: tenant.id, entity_id: entity.id, code: "PRIMARY")
      asset_class = AssetClass.active.where(tenant_id: tenant.id).find(values.fetch(:asset_class_id))

      FixedAsset.transaction do
        event = DomainEvents::Record.call(
          tenant_id: tenant.id, office_id: office.id, kind: "asset.created",
          actor: "u:#{actor.id}", actor_user_id: actor.id,
          ref: identity(values), payload: {
            "assetNumber" => values.fetch(:asset_number),
            "componentNumber" => values[:component_number].presence || "0000",
            "name" => values.fetch(:name), "assetClassCode" => asset_class.code,
            "capitalizationDate" => values.fetch(:capitalization_date).to_s
          }
        )
        asset = FixedAsset.create!(
          values.merge(
            tenant_id: tenant.id, entity: entity, office: office, asset_class: asset_class,
            created_by: actor, created_domain_event: event,
            component_number: values[:component_number].presence || "0000"
          )
        )
        create_terms!(asset, actor, event, "BOOK", true, book_terms, asset_class)
        create_terms!(asset, actor, event, "TAX_IT", false, tax_terms, asset_class)
        asset
      end
    end

    def create_terms!(asset, actor, event, code, posts, attributes, asset_class)
      values = attributes.to_h.symbolize_keys
      term = asset.asset_valuation_terms.create!(
        tenant_id: asset.tenant_id, created_by: actor, created_domain_event: event,
        valuation_code: code, posts_to_ledger: posts, depreciation_method: "straight_line",
        useful_life_months: values[:useful_life_months].presence || asset_class.default_useful_life_months,
        residual_value_minor: values[:residual_value_minor].presence || 0,
        depreciation_start_date: values[:depreciation_start_date].presence || asset.capitalization_date,
        valid_from: asset.capitalization_date
      )
      asset.asset_valuations.create!(
        tenant_id: asset.tenant_id, asset_valuation_term: term,
        valuation_code: code, posts_to_ledger: posts
      )
    end

    def identity(values)
      "#{values.fetch(:asset_number)}-#{values[:component_number].presence || '0000'}"
    end
  end
end
