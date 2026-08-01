# frozen_string_literal: true

class ContractScheduleLine < ApplicationRecord
  belongs_to :contract_schedule
  belongs_to :contract_milestone, optional: true
  belongs_to :posted_ledger_event, class_name: "LedgerEvent", optional: true

  validates :tenant_id, :sequence, :period_start, :period_end, :due_date,
    :original_effective_date, :amount_minor, :revenue_account_code, :status, presence: true
  validates :sequence, uniqueness: { scope: :contract_schedule_id },
    numericality: { only_integer: true, greater_than: 0 }
  validates :amount_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :status, inclusion: { in: %w[planned posted superseded] }
  validate :scope_matches
  validate :dates_are_coherent
  validate :posting_evidence_is_coherent

  scope :due_on_or_before, ->(date) { where(due_date: ..date) }

  private

  def scope_matches
    return unless contract_schedule

    errors.add(:contract_schedule, "must belong to the same company") if contract_schedule.tenant_id != tenant_id
    return unless contract_milestone
    return if contract_milestone.tenant_id == tenant_id &&
      contract_milestone.contract_performance_obligation_id ==
        contract_schedule.contract_performance_obligation_id

    errors.add(:contract_milestone, "must belong to the scheduled obligation")
  end

  def dates_are_coherent
    errors.add(:period_end, "cannot be before the period start") if period_end && period_start && period_end < period_start
  end

  def posting_evidence_is_coherent
    if status == "posted" && (posted_ledger_event.blank? || posted_at.blank?)
      errors.add(:base, "a posted schedule line needs its ledger event and posting timestamp")
    elsif status != "posted" && posted_ledger_event.present?
      errors.add(:status, "must be posted when a ledger event is linked")
    end
  end
end
