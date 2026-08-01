# frozen_string_literal: true

class Warehouse < ApplicationRecord
  TYPES = %w[general raw_material wip finished_goods].freeze

  belongs_to :entity
  belongs_to :office
  has_many :stock_balances, dependent: :restrict_with_exception
  has_many :inventory_movements, dependent: :restrict_with_exception

  normalizes :code, with: ->(code) { code.to_s.strip.upcase }
  validates :tenant_id, :code, :name, :warehouse_type, presence: true
  validates :code, uniqueness: { scope: :tenant_id }
  validates :warehouse_type, inclusion: { in: TYPES }
  validate :scope_matches

  scope :active, -> { where(active: true) }

  private

  def scope_matches
    return unless entity && office

    errors.add(:base, "warehouse must stay within one company and office") unless
      entity.tenant_id == tenant_id && office.tenant_id == tenant_id && office.entity_id == entity_id
  end
end
