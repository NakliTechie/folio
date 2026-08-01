# frozen_string_literal: true

module FixedAssets
  module RebuildValuations
    module_function

    def call(tenant_id:)
      AssetValuation.transaction do
        LedgerEvent.acquire_tenant_lock!(tenant_id)
        AssetValuation.where(tenant_id: tenant_id).order(:id).lock.each do |valuation|
          transactions = AssetTransaction.where(
            tenant_id: tenant_id, asset_valuation: valuation
          )
          retired = transactions.where(transaction_type: "retirement").exists?
          valuation.update!(
            gross_block_minor: retired ? 0 :
              transactions.where(transaction_type: "acquisition").sum(:amount_minor),
            accumulated_depreciation_minor: retired ? 0 :
              transactions.where(transaction_type: "depreciation").sum(:amount_minor),
            depreciation_posted_through: transactions.where(transaction_type: "depreciation")
              .maximum(:asset_value_date)
          )
        end
      end
    end
  end
end
