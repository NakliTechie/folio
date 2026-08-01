# frozen_string_literal: true

class ProcurementMatch < ApplicationRecord
  belongs_to :document
  belongs_to :document_line
  belongs_to :purchase_order
  belongs_to :purchase_order_line

  validates :tenant_id, :status, :billed_quantity, :ordered_unit_price_minor,
    :billed_unit_price_minor, presence: true
  validates :status, inclusion: { in: %w[matched exception] }
  validates :billed_quantity, numericality: { greater_than: 0 }
  validate :scope_matches
  validate :exceptions_are_structured
  validate :status_is_coherent

  private

  def scope_matches
    records = [ document, document_line, purchase_order, purchase_order_line ]
    errors.add(:base, "procurement match must stay within one company, bill, and order") unless
      records.all? { |record| record&.tenant_id == tenant_id } &&
        document_line&.document_id == document_id && purchase_order_line&.purchase_order_id == purchase_order_id &&
        document&.purchase_order_id == purchase_order_id &&
        document_line&.purchase_order_line_id == purchase_order_line_id &&
        document&.party_id == purchase_order&.vendor&.id
  end

  def exceptions_are_structured
    errors.add(:exceptions, "must be an array") unless exceptions.is_a?(Array)
  end

  def status_is_coherent
    return unless exceptions.is_a?(Array)

    errors.add(:status, "must reflect whether match exceptions exist") unless
      (status == "matched") == exceptions.empty?
  end
end
