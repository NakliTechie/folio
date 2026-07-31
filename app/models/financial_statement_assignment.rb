# frozen_string_literal: true

# Maps an account to exactly one presentation leaf in a statement-layout version.
class FinancialStatementAssignment < ApplicationRecord
  belongs_to :financial_statement_version
  belongs_to :financial_statement_section
  belongs_to :account

  validates :tenant_id, presence: true
  validates :account_id, uniqueness: { scope: :financial_statement_version_id }
  validate :references_share_tenant_and_version
  validate :published_mapping_can_only_change_before_posting, on: :update
  before_create :ensure_mapping_is_safe
  before_destroy :ensure_mapping_is_safe

  private

  def references_share_tenant_and_version
    return unless account && financial_statement_section && financial_statement_version

    valid = account.tenant_id == tenant_id &&
      financial_statement_section.tenant_id == tenant_id &&
      financial_statement_version.tenant_id == tenant_id &&
      financial_statement_section.financial_statement_version_id == financial_statement_version_id
    errors.add(:base, "account, section, and version must belong to the same tenant and version") unless valid
  end

  def published_mapping_can_only_change_before_posting
    return if financial_statement_version&.status == "draft" || !account&.posted?

    errors.add(:base, "a posted account's published statement mapping is immutable")
  end

  def ensure_mapping_is_safe
    return if financial_statement_version&.status == "draft" || !account&.posted?

    errors.add(:base, "a posted account's published statement mapping is immutable")
    throw :abort
  end
end
