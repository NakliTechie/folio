# frozen_string_literal: true

class PurchaseOrderLine < ApplicationRecord
  belongs_to :purchase_order
  belongs_to :item
  belongs_to :warehouse, optional: true
  has_many :goods_receipt_lines, dependent: :restrict_with_exception
  has_many :procurement_matches, dependent: :restrict_with_exception

  validates :tenant_id, :line_no, :description, :ordered_quantity, :received_quantity,
    :unit_price_minor, :line_total_minor, :account_code, :item_type, :item_snapshot, presence: true
  validates :ordered_quantity, numericality: { greater_than: 0 }
  validates :received_quantity, numericality: { greater_than_or_equal_to: 0 }
  validates :unit_price_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :line_total_minor, numericality: { only_integer: true, greater_than: 0 }
  validates :item_type, inclusion: { in: %w[service good] }
  validate :scope_matches
  validate :receipt_is_coherent

  def open_quantity
    ordered_quantity - received_quantity
  end

  def matched_quantity(excluding_document: nil)
    scope = procurement_matches.joins(:document).where.not(documents: { state: "reversed" })
    scope = scope.where.not(document_id: excluding_document.id) if excluding_document
    scope.sum(:billed_quantity)
  end

  private

  def scope_matches
    errors.add(:base, "purchase-order line must stay within one company") unless
      purchase_order&.tenant_id == tenant_id && item&.tenant_id == tenant_id &&
        (!warehouse || warehouse.tenant_id == tenant_id) && item&.item_type == item_type &&
        (item_type != "good" || warehouse.present?) && account_code == expected_account_code &&
        item_snapshot&.fetch("id", nil).to_i == item_id
  end

  def expected_account_code
    item_type == "good" ? item&.inventory_account_code : item&.expense_account_code
  end

  def receipt_is_coherent
    return unless ordered_quantity && received_quantity

    errors.add(:received_quantity, "cannot exceed ordered quantity") if received_quantity > ordered_quantity
  end
end
