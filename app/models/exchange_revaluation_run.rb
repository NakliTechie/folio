# frozen_string_literal: true

class ExchangeRevaluationRun < ApplicationRecord
  belongs_to :entity
  belongs_to :office
  belongs_to :created_by, class_name: "User"
  belongs_to :ledger_event, optional: true
  has_many :exchange_revaluation_items, dependent: :restrict_with_exception

  validates :tenant_id, :idempotency_key, :revaluation_date, :mode, :status, presence: true
  validates :idempotency_key, uniqueness: { scope: :tenant_id }
  validates :mode, inclusion: { in: %w[simulate post] }
  validates :status, inclusion: { in: %w[pending simulated posted failed] }
  validate :scope_matches

  private

  def scope_matches
    records = [ entity, office ]
    errors.add(:base, "revaluation run must stay within one company") unless
      records.all? { |record| record&.tenant_id == tenant_id }
  end
end
