# frozen_string_literal: true

class CostCenter < ApplicationRecord
  belongs_to :entity
  belongs_to :profit_center
  has_many :controlling_plan_lines, dependent: :restrict_with_exception

  normalizes :code, with: ->(value) { value.to_s.strip.upcase }
  validates :tenant_id, :code, :name, :valid_from, presence: true
  validates :code, uniqueness: { scope: :tenant_id }
  validate :scope_matches
  validate :range_valid

  scope :active, -> { where(active: true) }

  def effective_on?(date)
    active? && valid_from <= date && (valid_to.nil? || valid_to >= date) && profit_center.effective_on?(date)
  end

  private

  def scope_matches
    errors.add(:base, "cost center must stay within one company") unless
      entity&.tenant_id == tenant_id && profit_center&.tenant_id == tenant_id &&
        profit_center&.entity_id == entity_id
  end

  def range_valid
    errors.add(:valid_to, "cannot be before valid from") if valid_to && valid_from && valid_to < valid_from
  end
end
