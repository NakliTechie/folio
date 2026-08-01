# frozen_string_literal: true

class ContractAllocationLine < ApplicationRecord
  belongs_to :contract_allocation_run
  belongs_to :contract_performance_obligation
  has_many :contract_schedules, dependent: :restrict_with_exception

  validates :tenant_id, :standalone_selling_price_minor, :allocation_ratio,
    :allocated_price_minor, presence: true
  validates :contract_performance_obligation_id,
    uniqueness: { scope: :contract_allocation_run_id }
  validates :standalone_selling_price_minor, :allocated_price_minor,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :allocation_ratio, numericality: {
    greater_than_or_equal_to: 0, less_than_or_equal_to: 1
  }
  validate :scope_matches
  validate :immutable_after_creation, on: :update

  private

  def scope_matches
    return unless contract_allocation_run && contract_performance_obligation

    unless contract_allocation_run.tenant_id == tenant_id &&
        contract_performance_obligation.tenant_id == tenant_id &&
        contract_allocation_run.contract_id == contract_performance_obligation.contract_id
      errors.add(:base, "allocation line must stay within one company and contract")
    end
  end

  def immutable_after_creation
    errors.add(:base, "allocation lines are immutable; create a new allocation run") if has_changes_to_save?
  end
end
