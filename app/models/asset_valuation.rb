# frozen_string_literal: true

class AssetValuation < ApplicationRecord
  belongs_to :fixed_asset
  belongs_to :asset_valuation_term
  has_many :asset_transactions, dependent: :restrict_with_exception

  validates :tenant_id, :valuation_code, :gross_block_minor,
    :accumulated_depreciation_minor, presence: true
  validates :valuation_code, inclusion: { in: AssetValuationTerm::CODES }
  validates :gross_block_minor, :accumulated_depreciation_minor,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :scope_matches
  validate :carrying_amount_is_coherent

  def net_book_value_minor
    gross_block_minor - accumulated_depreciation_minor
  end

  private

  def scope_matches
    errors.add(:base, "asset valuation must stay within one company and valuation view") unless
      fixed_asset&.tenant_id == tenant_id && asset_valuation_term&.tenant_id == tenant_id &&
        asset_valuation_term&.fixed_asset_id == fixed_asset_id &&
        asset_valuation_term&.valuation_code == valuation_code &&
        asset_valuation_term&.posts_to_ledger == posts_to_ledger
  end

  def carrying_amount_is_coherent
    return unless gross_block_minor && accumulated_depreciation_minor

    errors.add(:accumulated_depreciation_minor, "cannot exceed gross block") if
      accumulated_depreciation_minor > gross_block_minor
  end
end
