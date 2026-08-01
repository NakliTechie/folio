# frozen_string_literal: true

class BankStatementImport < ApplicationRecord
  belongs_to :entity
  belongs_to :office
  belongs_to :created_by, class_name: "User"
  belongs_to :created_domain_event, class_name: "DomainEvent"
  belongs_to :reconciled_domain_event, class_name: "DomainEvent", optional: true
  has_many :bank_statement_lines, dependent: :restrict_with_exception

  validates :tenant_id, :bank_account_code, :currency, :file_name, :source_sha256,
    :statement_from, :statement_to, :opening_balance_minor, :closing_balance_minor,
    :row_count, :status, presence: true
  validates :source_sha256, length: { is: 64 }, uniqueness: {
    scope: %i[tenant_id bank_account_code]
  }
  validates :currency, length: { is: 3 }
  validates :row_count, numericality: { only_integer: true, greater_than: 0 }
  validates :status, inclusion: { in: %w[imported reconciled] }
  validate :scope_matches
  validate :period_is_coherent

  scope :recent_first, -> { order(statement_to: :desc, created_at: :desc) }

  private

  def scope_matches
    return unless entity && office && created_by && created_domain_event

    unless entity.tenant_id == tenant_id && office.tenant_id == tenant_id &&
        office.entity_id == entity_id && created_by.memberships.exists?(tenant_id: tenant_id) &&
        created_domain_event.tenant_id == tenant_id &&
        (!reconciled_domain_event || reconciled_domain_event.tenant_id == tenant_id)
      errors.add(:base, "bank statement import must stay within one company")
    end
  end

  def period_is_coherent
    errors.add(:statement_to, "cannot precede the statement start") if
      statement_from && statement_to && statement_to < statement_from
  end
end
