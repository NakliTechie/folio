# frozen_string_literal: true

class ControllingPlanLine < ApplicationRecord
  belongs_to :cost_center
  belongs_to :created_by, class_name: "User"

  normalizes :account_code, with: ->(value) { value.to_s.strip }
  normalizes :currency, with: ->(value) { value.to_s.strip.upcase }
  normalizes :version, with: ->(value) { value.to_s.strip.upcase }

  validates :tenant_id, :account_code, :version, :fiscal_year, :period_no,
    :currency, :amount_minor, presence: true
  validates :period_no, numericality: { only_integer: true, in: 1..16 }
  validates :amount_minor, numericality: { only_integer: true }
  validates :currency, length: { is: 3 }
  validate :scope_matches
  validate :account_is_available

  private

  def scope_matches
    errors.add(:base, "plan line must stay within one company") unless
      cost_center&.tenant_id == tenant_id && created_by&.memberships&.exists?(tenant_id: tenant_id)
  end

  def account_is_available
    errors.add(:account_code, "must be an active account in this company") unless
      Account.active.exists?(tenant_id: tenant_id, code: account_code)
  end
end
