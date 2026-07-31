# frozen_string_literal: true

class DocumentAllocation < ApplicationRecord
  MODES = %w[partial residual].freeze

  belongs_to :document
  has_one :settlement_reallocation, dependent: :restrict_with_exception

  validates :tenant_id, :line_no, :target_entry_line_id, :target_source_event_id,
    :target_line_no, :amount_minor, :clearing_mode, presence: true
  validates :line_no, :target_line_no, numericality: { only_integer: true, greater_than: 0 }
  validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
  validates :clearing_mode, inclusion: { in: MODES }
  validates :target_source_event_id, uniqueness: { scope: %i[document_id target_line_no] }
  validate :document_belongs_to_tenant

  def target_item
    EntryLine.find_by(
      tenant_id: tenant_id,
      source_event_id: target_source_event_id,
      line_no: target_line_no
    )
  end

  def reset? = target_reset_event_id.present? && settlement_reset_event_id.present?
  def applied? = target_clearing_event_id.present? && !reset?

  private

  def document_belongs_to_tenant
    errors.add(:document, "must belong to the same tenant") if document && document.tenant_id != tenant_id
  end
end
