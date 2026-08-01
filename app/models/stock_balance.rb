# frozen_string_literal: true

class StockBalance < ApplicationRecord
  belongs_to :item
  belongs_to :warehouse

  validates :tenant_id, :quantity, :inventory_value_minor, presence: true
  validates :quantity, numericality: { greater_than_or_equal_to: 0 }
  validates :inventory_value_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :scope_matches
  validate :zero_position_is_coherent

  def average_unit_cost_minor
    return 0 if quantity.zero?

    (inventory_value_minor.to_d / quantity).round(0, BigDecimal::ROUND_HALF_UP).to_i
  end

  private

  def scope_matches
    return unless item && warehouse

    errors.add(:base, "stock balance must stay within one company") unless
      item.tenant_id == tenant_id && warehouse.tenant_id == tenant_id && item.item_type == "good"
  end

  def zero_position_is_coherent
    return unless quantity && inventory_value_minor

    errors.add(:inventory_value_minor, "must be zero when quantity is zero") if
      quantity.zero? && inventory_value_minor.nonzero?
  end
end
