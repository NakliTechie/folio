# frozen_string_literal: true

# One node in a versioned balance-sheet or profit-and-loss presentation tree.
class FinancialStatementSection < ApplicationRecord
  STATEMENT_TYPES = %w[balance_sheet profit_and_loss].freeze
  NORMAL_BALANCES = %w[debit credit].freeze

  belongs_to :financial_statement_version
  belongs_to :parent, class_name: "FinancialStatementSection", optional: true
  has_many :children, -> { order(:sort_order, :id) },
    class_name: "FinancialStatementSection", foreign_key: :parent_id, dependent: :restrict_with_exception,
    inverse_of: :parent
  has_many :financial_statement_assignments, dependent: :restrict_with_exception

  validates :tenant_id, :statement_type, :code, :label, :normal_balance, :sort_order, presence: true
  validates :code, uniqueness: { scope: :financial_statement_version_id }
  validates :statement_type, inclusion: { in: STATEMENT_TYPES }
  validates :normal_balance, inclusion: { in: NORMAL_BALANCES }
  validate :parent_matches_version_and_statement
  validate :published_version_is_immutable, on: :update
  before_create :ensure_draft_version
  before_destroy :ensure_draft_version

  private

  def parent_matches_version_and_statement
    return unless parent

    if parent.financial_statement_version_id != financial_statement_version_id ||
       parent.statement_type != statement_type || parent.tenant_id != tenant_id
      errors.add(:parent, "must belong to the same tenant, version, and statement")
    end
  end

  def published_version_is_immutable
    return if financial_statement_version&.status == "draft"

    errors.add(:base, "published statement sections are immutable; clone a draft")
  end

  def ensure_draft_version
    return if financial_statement_version&.status == "draft"

    errors.add(:base, "published statement sections are immutable; clone a draft")
    throw :abort
  end
end
