# frozen_string_literal: true

# Document identity + lifecycle (spec §7, §8). The IDENTITY object plus the draft → parked →
# posted → reversed lifecycle. external_reference drives duplicate-invoice detection;
# document_number is allocated from a NumberRange (never a Postgres sequence) inside the
# posting transaction. A document type declares how it posts — the core stays generic.
class Document < ApplicationRecord
  STATES = %w[draft parked posted reversed].freeze

  belongs_to :document_type
  belongs_to :party, optional: true
  belongs_to :tax_registration, optional: true
  belongs_to :reverses, class_name: "Document", foreign_key: :reverses_document_id, optional: true
  belongs_to :reversed_by, class_name: "Document", foreign_key: :reversed_by_document_id, optional: true
  has_many :document_lines, -> { order(:line_no) }, dependent: :destroy
  has_many :entries, dependent: :nullify

  validates :tenant_id, :entity_id, :office_id, :doc_type, :fiscal_year,
    :document_date, :posting_date, presence: true
  validates :state, inclusion: { in: STATES }
  validate :document_type_matches_document
  validate :invoice_totals_are_consistent

  def posted? = state == "posted"
  def postable? = %w[draft parked].include?(state)
  def reversible? = posted? && reversed_by_document_id.nil?

  private

  def document_type_matches_document
    return unless document_type

    unless document_type.tenant_id == tenant_id && document_type.code == doc_type
      errors.add(:document_type, "must belong to the same tenant and match doc_type")
    end
  end

  def invoice_totals_are_consistent
    return if subtotal_minor.nil? && tax_minor.nil? && total_minor.nil?
    return if subtotal_minor.to_i.positive? && tax_minor.to_i >= 0 && total_minor == subtotal_minor + tax_minor

    errors.add(:total_minor, "must equal the positive subtotal plus tax")
  end
end
