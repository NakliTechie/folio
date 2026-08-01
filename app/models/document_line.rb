# frozen_string_literal: true

# A user-entered document line, generic over type. Signed minor units (+ debit, − credit).
class DocumentLine < ApplicationRecord
  belongs_to :document
  belongs_to :item, optional: true
  belongs_to :purchase_order_line, optional: true
  belongs_to :credited_document_line, class_name: "DocumentLine", optional: true
  belongs_to :debited_document_line, class_name: "DocumentLine", optional: true
  has_one :procurement_match, dependent: :destroy
  normalizes :currency, with: ->(currency) { currency.to_s.upcase }
  normalizes :account_code, with: ->(code) { code.to_s.strip }
  validates :tenant_id, :line_no, :account_code, :amount_minor, :currency, :minor_unit_exponent,
            presence: true
  validates :amount_minor, numericality: { only_integer: true, other_than: 0 }
  validates :minor_unit_exponent, numericality: { only_integer: true, in: 0..4 }
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }
  validates :quantity, numericality: { greater_than: 0 }, if: -> { item_id.present? }
  validates :unit_price_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 },
    if: -> { item_id.present? }
  validates :taxable_minor, numericality: { only_integer: true, greater_than: 0 }, if: -> { item_id.present? }
  validates :hsn_sac_code, format: { with: /\A(?:\d{2}|\d{4}|\d{6}|\d{8})\z/ }, if: -> { item_id.present? }
  validates :tax_rate_basis_points, numericality: { only_integer: true, in: 0..4000 },
    if: -> { item_id.present? }
  validates :cess_rate_basis_points, numericality: { only_integer: true, in: 0..10_000 },
    if: -> { item_id.present? }
end
