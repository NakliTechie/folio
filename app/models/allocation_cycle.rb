# frozen_string_literal: true

class AllocationCycle < ApplicationRecord
  belongs_to :entity
  belongs_to :office
  belongs_to :sender_cost_center, class_name: "CostCenter"
  has_many :allocation_receivers, dependent: :restrict_with_exception
  has_many :allocation_runs, dependent: :restrict_with_exception

  normalizes :code, with: ->(value) { value.to_s.strip.upcase }
  normalizes :source_account_code, with: ->(value) { value.to_s.strip }
  validates :tenant_id, :code, :name, :allocation_type, :source_account_code, :valid_from, presence: true
  validates :code, uniqueness: { scope: :tenant_id }
  validates :allocation_type, inclusion: { in: %w[distribution] }
  validate :scope_matches
  validate :source_account_is_available

  scope :active, -> { where(active: true) }

  def effective_on?(date)
    active? && valid_from <= date && (valid_to.nil? || valid_to >= date)
  end

  private

  def scope_matches
    errors.add(:base, "allocation cycle must stay within one company and entity") unless
      entity&.tenant_id == tenant_id && office&.tenant_id == tenant_id &&
        sender_cost_center&.tenant_id == tenant_id && office&.entity_id == entity_id &&
        sender_cost_center&.entity_id == entity_id
  end

  def source_account_is_available
    account = Account.active.find_by(tenant_id: tenant_id, code: source_account_code)
    errors.add(:source_account_code, "must be an active expense account in this company") unless
      account&.account_type == "expense"
  end
end
