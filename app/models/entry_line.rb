# frozen_string_literal: true

# One posting line (spec §3). Committed dimensions are real typed columns; uncommitted
# ones live in `extra` and are NEVER aggregated in a statutory report. Amounts live in the
# journal_entry_line_amounts child table (D4), so the line carries no debit/credit pair.
class EntryLine < ApplicationRecord
  belongs_to :entry
  belongs_to :ledger, optional: true
  belongs_to :party, optional: true
  belongs_to :item, optional: true
  belongs_to :fixed_asset, optional: true
  belongs_to :tax_registration, optional: true
  belongs_to :residual_of, class_name: "EntryLine", optional: true
  has_many :amounts, class_name: "JournalEntryLineAmount", dependent: :destroy
  has_many :residuals, class_name: "EntryLine", foreign_key: :residual_of_line_id, dependent: :nullify

  # Still-outstanding open items (open_item set, not yet fully cleared).
  scope :open_items, -> { where(open_item: true, cleared_on: nil) }

  LINE_CLASSES = %w[real statistical].freeze
  # item_class replaces SAP's entire Special G/L machinery — one field, decided now.
  ITEM_CLASSES = %w[normal down_payment statistical noted].freeze
  PARTY_ROLES  = %w[customer vendor employee lender bank tax_authority other].freeze
  TAX_COMPONENTS = %w[cgst sgst utgst igst cess].freeze

  validates :tenant_id, :entry_id, :line_no, :account_code,
            :ledger_id, :entity_id, :office_id, presence: true
  validates :line_class, inclusion: { in: LINE_CLASSES }
  validates :item_class, inclusion: { in: ITEM_CLASSES }, allow_nil: true
  validates :party_role, inclusion: { in: PARTY_ROLES }, allow_nil: true
  validates :tax_component, inclusion: { in: TAX_COMPONENTS }, allow_nil: true
end
