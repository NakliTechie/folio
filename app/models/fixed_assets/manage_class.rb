# frozen_string_literal: true

module FixedAssets
  module ManageClass
    ATTRIBUTES = %i[
      code name apc_account_code accumulated_depreciation_account_code
      depreciation_expense_account_code gain_account_code loss_account_code
      default_useful_life_months
    ].freeze

    module_function

    def create!(tenant:, actor:, attributes:)
      AssetClass.transaction do
        record = AssetClass.create!(attributes.to_h.symbolize_keys.slice(*ATTRIBUTES).merge(tenant_id: tenant.id))
        MasterData::Audit.append!(
          tenant_id: tenant.id, actor: actor, action: "asset_class.created", ref: record.code,
          subject: { "id" => record.id, "code" => record.code, "name" => record.name },
          changes: record.attributes.slice(*ATTRIBUTES.map(&:to_s))
            .transform_values { |value| { "to" => value } }
        )
        record
      end
    end
  end
end
