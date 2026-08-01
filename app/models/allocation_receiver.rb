# frozen_string_literal: true

class AllocationReceiver < ApplicationRecord
  belongs_to :allocation_cycle
  belongs_to :cost_center

  validates :tenant_id, :weight_basis_points, presence: true
  validates :weight_basis_points, numericality: { only_integer: true, in: 1..10_000 }
  validate :scope_matches

  private

  def scope_matches
    errors.add(:base, "allocation receiver must stay within the cycle entity") unless
      allocation_cycle&.tenant_id == tenant_id && cost_center&.tenant_id == tenant_id &&
        allocation_cycle&.entity_id == cost_center&.entity_id &&
        allocation_cycle&.sender_cost_center_id != cost_center_id
  end
end
