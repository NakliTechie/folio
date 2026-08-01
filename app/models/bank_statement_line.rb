# frozen_string_literal: true

class BankStatementLine < ApplicationRecord
  belongs_to :bank_statement_import
  belongs_to :matched_by, class_name: "User", optional: true

  validates :tenant_id, :line_no, :booking_date, :value_date, :amount_minor,
    :currency, :description, :status, presence: true
  validates :line_no, uniqueness: { scope: :bank_statement_import_id },
    numericality: { only_integer: true, greater_than: 0 }
  validates :amount_minor, numericality: { only_integer: true, other_than: 0 }
  validates :currency, length: { is: 3 }
  validates :status, inclusion: { in: %w[unmatched matched ignored] }
  validates :match_method, inclusion: { in: %w[exact manual] }, allow_nil: true
  validate :scope_matches
  validate :resolution_is_coherent

  scope :in_statement_order, -> { order(:line_no) }

  def matched_entry_line
    return unless matched_ledger_event_id && matched_entry_line_no

    EntryLine.find_by(
      tenant_id: tenant_id, source_event_id: matched_ledger_event_id,
      line_no: matched_entry_line_no
    )
  end

  private

  def scope_matches
    return unless bank_statement_import

    errors.add(:bank_statement_import, "must belong to the same company") if
      bank_statement_import.tenant_id != tenant_id || bank_statement_import.currency != currency
  end

  def resolution_is_coherent
    if status == "matched"
      unless match_method && matched_ledger_event_id && matched_entry_line_no && matched_by && matched_at
        errors.add(:base, "a matched bank line needs complete ledger and actor evidence")
      end
    elsif status == "ignored"
      errors.add(:ignore_reason, "is required for an ignored line") if ignore_reason.blank?
      if matched_ledger_event_id || matched_entry_line_no || match_method || matched_by || matched_at
        errors.add(:status, "cannot retain ledger evidence when ignored")
      end
    elsif matched_ledger_event_id || matched_entry_line_no || match_method || matched_by || matched_at || ignore_reason
      errors.add(:status, "must be matched when ledger evidence is present")
    end
  end
end
