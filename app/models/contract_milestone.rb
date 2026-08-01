# frozen_string_literal: true

class ContractMilestone < ApplicationRecord
  STATUSES = %w[planned achieved cancelled].freeze

  belongs_to :contract
  belongs_to :contract_performance_obligation
  has_many :contract_schedule_lines, dependent: :restrict_with_exception

  validates :tenant_id, :milestone_no, :description, :planned_date,
    :recognition_amount_minor, :status, presence: true
  validates :milestone_no, uniqueness: {
    scope: %i[tenant_id contract_performance_obligation_id]
  }, numericality: { only_integer: true, greater_than: 0 }
  validates :recognition_amount_minor,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :status, inclusion: { in: STATUSES }
  validate :scope_matches
  validate :achievement_evidence_is_coherent

  scope :in_number_order, -> { order(:milestone_no) }

  private

  def scope_matches
    return unless contract && contract_performance_obligation

    errors.add(:contract, "must belong to the same company") if contract.tenant_id != tenant_id
    unless contract_performance_obligation.tenant_id == tenant_id &&
        contract_performance_obligation.contract_id == contract_id
      errors.add(:contract_performance_obligation, "must belong to this contract")
    end
  end

  def achievement_evidence_is_coherent
    errors.add(:achieved_date, "is required when achieved") if status == "achieved" && achieved_date.blank?
    if acceptance_required? && status == "achieved" && acceptance_date.blank?
      errors.add(:acceptance_date, "is required when an acceptance milestone is achieved")
    end
  end
end
