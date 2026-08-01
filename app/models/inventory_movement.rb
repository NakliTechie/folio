# frozen_string_literal: true

class InventoryMovement < ApplicationRecord
  belongs_to :inventory_transaction
  belongs_to :item
  belongs_to :warehouse
  belongs_to :ledger_event

  validates :tenant_id, :entry_line_no, :quantity, :inventory_value_minor,
    :balance_quantity_after, :balance_value_after_minor, presence: true
  validates :entry_line_no, numericality: { only_integer: true, greater_than: 0 }
  validates :quantity, numericality: { other_than: 0 }
  validates :inventory_value_minor, numericality: { only_integer: true, other_than: 0 }
  validates :balance_quantity_after, numericality: { greater_than_or_equal_to: 0 }
  validates :balance_value_after_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :scope_matches

  private

  def scope_matches
    records = [ inventory_transaction, item, warehouse, ledger_event ]
    errors.add(:base, "inventory movement must stay within one company") unless
      records.all? { |record| record&.tenant_id == tenant_id } &&
        inventory_transaction&.item_id == item_id &&
        inventory_transaction&.ledger_event_id == ledger_event_id
  end
end
