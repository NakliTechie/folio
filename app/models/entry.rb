# frozen_string_literal: true

# The accounting entry header (spec §6, §7, §11). Carries the four dates and the STORED
# period identity; the balance invariant it anchors is asserted per (entry, ledger) by
# Posting::PostEntry (B3.2), never globally. document_id is optional — a run is a valid
# document origin (§8), so not every entry has a document.
class Entry < ApplicationRecord
  belongs_to :document, optional: true
  belongs_to :reverses, class_name: "Entry", optional: true
  belongs_to :reversed_by, class_name: "Entry", optional: true
  has_many :entry_lines, dependent: :destroy

  # period_no ∈ {0} ∪ [1..12] ∪ [13..16]. Stored, never derived — special periods and
  # carryforward (period 0) are not recoverable from posting_date.
  PERIOD_RANGE = (0..16).freeze

  validates :tenant_id, :document_date, :posting_date, :entered_at,
            :fiscal_year, :period_no, presence: true
  validates :period_no, inclusion: { in: PERIOD_RANGE }
end
