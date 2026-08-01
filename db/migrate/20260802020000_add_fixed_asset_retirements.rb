# frozen_string_literal: true

class AddFixedAssetRetirements < ActiveRecord::Migration[8.1]
  def up
    add_column :fixed_assets, :retired_on, :date
    remove_check_constraint :asset_transactions, name: "asset_transactions_type_valid"
    add_check_constraint :asset_transactions,
      "transaction_type IN ('acquisition', 'depreciation', 'retirement')",
      name: "asset_transactions_type_valid"
  end

  def down
    remove_check_constraint :asset_transactions, name: "asset_transactions_type_valid"
    add_check_constraint :asset_transactions,
      "transaction_type IN ('acquisition', 'depreciation')",
      name: "asset_transactions_type_valid"
    remove_column :fixed_assets, :retired_on
  end
end
