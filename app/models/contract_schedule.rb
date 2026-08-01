# frozen_string_literal: true

class ContractSchedule < ApplicationRecord
  belongs_to :office
  belongs_to :contract
  belongs_to :contract_performance_obligation
  belongs_to :contract_allocation_line
  belongs_to :created_domain_event, class_name: "DomainEvent"
  has_many :contract_schedule_lines, dependent: :restrict_with_exception

  validates :tenant_id, :version, :kind, :method, :accounting_principle,
    :currency, :status, :generated_at, presence: true
  validates :version, uniqueness: {
    scope: %i[tenant_id contract_performance_obligation_id]
  }, numericality: { only_integer: true, greater_than: 0 }
  validates :kind, inclusion: { in: %w[revenue] }
  validates :method, inclusion: { in: %w[straight_line milestone] }
  validates :accounting_principle, inclusion: { in: %w[ind_as] }
  validates :status, inclusion: { in: %w[current superseded] }
  validates :currency, length: { is: 3 }
  validate :scope_matches

  scope :current, -> { where(status: "current") }

  private

  def scope_matches
    records = [ office, contract, contract_performance_obligation, contract_allocation_line ]
    return if records.any?(&:nil?)

    same_tenant = records.all? { |record| record.tenant_id == tenant_id }
    same_contract = contract_performance_obligation.contract_id == contract_id &&
      contract_allocation_line.contract_performance_obligation_id == contract_performance_obligation_id
    errors.add(:base, "schedule must stay within one company and contract") unless same_tenant && same_contract
  end
end
