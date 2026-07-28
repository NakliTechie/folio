# frozen_string_literal: true

# A currency slot on a line (spec §4). One row per (line, slot). Signed minor units — no
# debit/credit pair (that lives only in the .khata export projection). minor_unit_exponent
# is per ISO 4217, never a hardcoded ×100.
class JournalEntryLineAmount < ApplicationRecord
  belongs_to :entry_line

  SLOT_ROLES  = %w[transaction functional group].freeze
  RATE_BASES  = %w[document_date posting_date translation_date].freeze

  validates :entry_line_id, :slot_role, :currency, :minor_unit_exponent,
            :amount_minor, presence: true
  validates :slot_role, inclusion: { in: SLOT_ROLES }
  validates :rate_basis, inclusion: { in: RATE_BASES }, allow_nil: true
  validates :currency, length: { is: 3 }
  # The group slot must pin its translation basis (§4 non-negotiable #2).
  validates :rate_basis, presence: true, if: -> { slot_role == "group" && rate.present? }
end
