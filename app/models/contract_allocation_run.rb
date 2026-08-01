# frozen_string_literal: true

class ContractAllocationRun < ApplicationRecord
  belongs_to :contract
  belongs_to :created_domain_event, class_name: "DomainEvent"
  has_many :contract_allocation_lines, dependent: :restrict_with_exception

  validates :tenant_id, :version, :effective_date, :method, :trigger,
    :transaction_price_minor, :total_ssp_minor, presence: true
  validates :version, uniqueness: { scope: %i[tenant_id contract_id] },
    numericality: { only_integer: true, greater_than: 0 }
  validates :method, inclusion: { in: %w[relative_ssp] }
  validates :trigger, inclusion: { in: %w[initial modification] }
  validates :transaction_price_minor,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :total_ssp_minor, numericality: { only_integer: true, greater_than: 0 }
  validate :tenant_matches_contract
  validate :immutable_after_creation, on: :update

  scope :in_version_order, -> { order(:version) }

  private

  def tenant_matches_contract
    errors.add(:contract, "must belong to the same company") if contract && contract.tenant_id != tenant_id
  end

  def immutable_after_creation
    errors.add(:base, "allocation runs are immutable; create a new version") if has_changes_to_save?
  end
end
