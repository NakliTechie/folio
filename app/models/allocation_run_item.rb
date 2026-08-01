# frozen_string_literal: true

class AllocationRunItem < ApplicationRecord
  belongs_to :allocation_run
  belongs_to :sender_cost_center, class_name: "CostCenter"
  belongs_to :receiver_cost_center, class_name: "CostCenter"

  validates :tenant_id, :account_code, :weight_basis_points, :amount_minor, presence: true
  validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
  validate :scope_matches

  private

  def scope_matches
    errors.add(:base, "allocation result must stay within one company") unless
      [ allocation_run, sender_cost_center, receiver_cost_center ].all? do |record|
        record&.tenant_id == tenant_id
      end
  end
end
