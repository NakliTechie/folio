# frozen_string_literal: true

class PurchaseOrderNumberRange < ApplicationRecord
  validates :tenant_id, :entity_id, :office_id, :fiscal_year, :next_value, presence: true
  validates :next_value, numericality: { only_integer: true, greater_than: 0 }
end
