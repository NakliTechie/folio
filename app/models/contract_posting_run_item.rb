# frozen_string_literal: true

class ContractPostingRunItem < ApplicationRecord
  belongs_to :contract_posting_run
  belongs_to :contract_schedule_line
  belongs_to :ledger_event, optional: true

  validates :tenant_id, :status, presence: true
  validates :contract_schedule_line_id, uniqueness: { scope: :contract_posting_run_id }
  validates :status, inclusion: { in: %w[pending simulated posted skipped failed] }
  validate :scope_matches

  private

  def scope_matches
    return unless contract_posting_run && contract_schedule_line

    same_tenant = contract_posting_run.tenant_id == tenant_id && contract_schedule_line.tenant_id == tenant_id
    same_contract = contract_schedule_line.contract_schedule.contract_id == contract_posting_run.contract_id
    errors.add(:base, "posting item must stay within one company and contract") unless same_tenant && same_contract
  end
end
