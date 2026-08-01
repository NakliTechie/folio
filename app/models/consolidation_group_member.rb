# frozen_string_literal: true

class ConsolidationGroupMember < ApplicationRecord
  belongs_to :consolidation_group
  belongs_to :entity

  validates :tenant_id, :ownership_basis_points, :effective_from, presence: true
  validates :entity_id, uniqueness: { scope: :consolidation_group_id }
  validates :ownership_basis_points, numericality: { only_integer: true, equal_to: 10_000 }
  validate :scope_and_policy_match

  def effective_on?(date)
    effective_from <= date && (effective_to.nil? || effective_to >= date)
  end

  private

  def scope_and_policy_match
    errors.add(:base, "group member must stay in one company and presentation currency") unless
      consolidation_group&.tenant_id == tenant_id && entity&.tenant_id == tenant_id &&
        entity&.functional_currency == consolidation_group&.presentation_currency
  end
end
