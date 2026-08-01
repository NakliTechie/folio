# frozen_string_literal: true

# A thin account master (B3.5, seed of the Batch 5/6 account master). `code` is the stable
# identifier; entry_lines reference it via account_code.
class Account < ApplicationRecord
  TYPES = %w[asset liability equity income expense].freeze
  CODE_ORDER = <<~SQL.squish.freeze
    CASE WHEN accounts.code ~ '^[0-9]+$' THEN 0 ELSE 1 END,
    CASE WHEN accounts.code ~ '^[0-9]+$' THEN accounts.code::numeric END,
    accounts.code
  SQL

  has_many :financial_statement_assignments, dependent: :restrict_with_exception

  validates :tenant_id, :code, :name, :account_type, presence: true
  validates :code, uniqueness: { scope: :tenant_id }
  validates :account_type, inclusion: { in: TYPES }
  validate :stable_fields_stay_immutable_after_use, on: :update

  scope :active, -> { where(active: true) }
  scope :in_code_order, -> { order(Arel.sql(CODE_ORDER)) }

  def code_locked?
    stable_code = code_in_database || code
    EntryLine.where(tenant_id: tenant_id, account_code: stable_code).exists? ||
      DocumentLine.where(tenant_id: tenant_id, account_code: stable_code).exists?
  end

  def posted?
    EntryLine.where(tenant_id: tenant_id, account_code: code_in_database || code).exists?
  end

  private

  def stable_fields_stay_immutable_after_use
    errors.add(:code, "cannot change after the account is referenced") if will_save_change_to_code? && code_locked?
    if will_save_change_to_account_type? && posted?
      errors.add(:account_type, "cannot change after the account has postings")
    end
    if will_save_change_to_monetary? && posted?
      errors.add(:monetary, "classification cannot change after the account has postings")
    end
    if will_save_change_to_active?(from: true, to: false) && open_draft_references?
      errors.add(:active, "cannot be deactivated while an open draft references the account")
    end
  end

  def open_draft_references?
    Document.joins(:document_lines)
      .where(tenant_id: tenant_id, state: %w[draft parked], document_lines: { account_code: code_in_database || code })
      .exists?
  end
end
