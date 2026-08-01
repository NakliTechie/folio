# frozen_string_literal: true

module FixedAssets
  InvalidAsset = Class.new(ArgumentError)

  module_function

  def snapshot(asset)
    {
      "assetId" => asset.id,
      "assetNumber" => asset.asset_number,
      "componentNumber" => asset.component_number,
      "name" => asset.name,
      "assetClassCode" => asset.asset_class.code,
      "status" => asset.status
    }
  end
end
