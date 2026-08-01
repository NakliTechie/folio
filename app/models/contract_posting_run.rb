# frozen_string_literal: true

class ContractPostingRun < ApplicationRecord
  belongs_to :office
  belongs_to :contract
  belongs_to :created_by, class_name: "User"
  has_many :contract_posting_run_items, dependent: :restrict_with_exception

  validates :tenant_id, :idempotency_key, :run_type, :mode, :status,
    :posting_date, presence: true
  validates :idempotency_key, uniqueness: { scope: :tenant_id }
  validates :run_type, inclusion: { in: %w[revenue_recognition] }
  validates :mode, inclusion: { in: %w[simulate post] }
  validates :status, inclusion: { in: %w[pending running simulated posted failed] }
  validate :scope_matches

  private

  def scope_matches
    return unless office && contract && created_by

    unless office.tenant_id == tenant_id && contract.tenant_id == tenant_id &&
        created_by.tenants.where(id: tenant_id).exists?
      errors.add(:base, "posting run must stay within one company")
    end
  end
end
