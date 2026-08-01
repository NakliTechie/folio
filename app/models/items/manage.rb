# frozen_string_literal: true

module Items
  module Manage
    AUDITED_FIELDS = %w[
      code name item_type description hsn_sac_code unit_of_measure tax_rate_basis_points
      cess_rate_basis_points income_account_code expense_account_code active
      inventory_class revision valuation_method inventory_account_code
    ].freeze

    module_function

    def create!(tenant:, attributes:, actor:)
      Item.transaction do
        item = Item.create!(attributes.merge(tenant_id: tenant.id))
        append_event!(item, "item.created", actor,
          item.attributes.slice(*AUDITED_FIELDS).transform_values { |value| { "to" => value } })
        item
      end
    end

    def update!(item:, attributes:, actor:)
      Item.transaction do
        item.lock!
        item.assign_attributes(attributes)
        changes = item.changes.slice(*AUDITED_FIELDS).transform_values do |before, after|
          { "from" => before, "to" => after }
        end
        return item if changes.empty?

        item.save!
        action = MasterData::Audit.lifecycle_action("item", changes)
        append_event!(item, action, actor, changes)
        item
      end
    end

    def append_event!(item, action, actor, changes)
      MasterData::Audit.append!(
        tenant_id: item.tenant_id, actor: actor, action: action, ref: item.code,
        subject: {
          "id" => item.id, "code" => item.code, "name" => item.name,
          "itemType" => item.item_type, "active" => item.active
        },
        changes: changes
      )
    end
  end
end
