# frozen_string_literal: true

# A user-entered document line, generic over type. Signed minor units (+ debit, − credit).
class DocumentLine < ApplicationRecord
  belongs_to :document
  normalizes :currency, with: ->(currency) { currency.to_s.upcase }
  normalizes :account_code, with: ->(code) { code.to_s.strip }
  validates :tenant_id, :line_no, :account_code, :amount_minor, :currency, :minor_unit_exponent,
            presence: true
  validates :amount_minor, numericality: { only_integer: true, other_than: 0 }
  validates :minor_unit_exponent, numericality: { only_integer: true, in: 0..4 }
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }
end
