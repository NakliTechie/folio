# frozen_string_literal: true

class SettlementReallocation < ApplicationRecord
  belongs_to :document_allocation

  validates :tenant_id, :target_entry_line_id, :target_source_event_id, :target_line_no,
    :amount_minor, :clearing_mode, presence: true
  validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
  validates :clearing_mode, inclusion: { in: DocumentAllocation::MODES }

  def target_item
    EntryLine.find_by(
      tenant_id: tenant_id, source_event_id: target_source_event_id, line_no: target_line_no
    )
  end
end
