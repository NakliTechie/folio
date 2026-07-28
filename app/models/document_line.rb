# frozen_string_literal: true

# A user-entered document line, generic over type. Signed minor units (+ debit, − credit).
class DocumentLine < ApplicationRecord
  belongs_to :document
  validates :tenant_id, :line_no, :account_code, :amount_minor, :currency, :minor_unit_exponent,
            presence: true
  validates :currency, length: { is: 3 }
end
