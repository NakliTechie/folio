# frozen_string_literal: true

class IntercompanyTransaction < ApplicationRecord
  belongs_to :consolidation_group
  belongs_to :seller_entity, class_name: "Entity"
  belongs_to :buyer_entity, class_name: "Entity"
  belongs_to :created_by, class_name: "User"
  belongs_to :ledger_event
  has_one :consolidation_elimination_run, dependent: :restrict_with_exception

  validates :tenant_id, :transaction_code, :idempotency_key, :request_sha256,
    :posting_date, :currency, :amount_minor, :description, presence: true
  validates :transaction_code, :idempotency_key, uniqueness: { scope: :tenant_id }
  validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
  validate :scope_matches

  private

  def scope_matches
    member_ids = consolidation_group&.consolidation_group_members&.map(&:entity_id) || []
    errors.add(:base, "intercompany transaction must stay within one consolidation group") unless
      consolidation_group&.tenant_id == tenant_id && seller_entity&.tenant_id == tenant_id &&
        buyer_entity&.tenant_id == tenant_id && seller_entity_id != buyer_entity_id &&
        member_ids.include?(seller_entity_id) && member_ids.include?(buyer_entity_id) &&
        ledger_event&.tenant_id == tenant_id && created_by&.memberships&.exists?(tenant_id: tenant_id)
  end
end
