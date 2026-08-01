# frozen_string_literal: true

class GoodsReceiptLine < ApplicationRecord
  belongs_to :goods_receipt
  belongs_to :purchase_order_line
  belongs_to :inventory_transaction, optional: true

  validates :tenant_id, :received_quantity, presence: true
  validates :received_quantity, numericality: { greater_than: 0 }
  validate :scope_matches

  private

  def scope_matches
    errors.add(:base, "goods-receipt line must stay within one order and company") unless
      goods_receipt&.tenant_id == tenant_id && purchase_order_line&.tenant_id == tenant_id &&
        goods_receipt&.purchase_order_id == purchase_order_line&.purchase_order_id &&
        inventory_evidence_matches?
  end

  def inventory_evidence_matches?
    if purchase_order_line&.item_type == "good"
      inventory_transaction&.tenant_id == tenant_id &&
        inventory_transaction.item_id == purchase_order_line.item_id &&
        inventory_transaction.destination_warehouse_id == purchase_order_line.warehouse_id
    else
      inventory_transaction.nil?
    end
  end
end
