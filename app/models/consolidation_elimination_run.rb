# frozen_string_literal: true

class ConsolidationEliminationRun < ApplicationRecord
  belongs_to :consolidation_group
  belongs_to :intercompany_transaction
  belongs_to :created_by, class_name: "User"
  belongs_to :ledger_event

  validates :tenant_id, :idempotency_key, :request_sha256, :posting_date, presence: true
  validates :idempotency_key, uniqueness: { scope: :tenant_id }
  validates :intercompany_transaction_id, uniqueness: true
  validate :scope_matches

  private

  def scope_matches
    errors.add(:base, "elimination must stay within one company and consolidation group") unless
      consolidation_group&.tenant_id == tenant_id &&
        intercompany_transaction&.tenant_id == tenant_id &&
        intercompany_transaction&.consolidation_group_id == consolidation_group_id &&
        ledger_event&.tenant_id == tenant_id && created_by&.memberships&.exists?(tenant_id: tenant_id)
  end
end
