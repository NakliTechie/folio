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
  belongs_to :contract, optional: true
  belongs_to :purchase_order, optional: true
  belongs_to :credit_note_for, class_name: "Document", foreign_key: :credit_note_for_document_id, optional: true
  belongs_to :debit_note_for, class_name: "Document", foreign_key: :debit_note_for_document_id, optional: true
  belongs_to :reverses, class_name: "Document", foreign_key: :reverses_document_id, optional: true
  belongs_to :reversed_by, class_name: "Document", foreign_key: :reversed_by_document_id, optional: true
  has_many :document_lines, -> { order(:line_no) }, dependent: :destroy
  has_many :document_allocations, -> { order(:line_no) }, dependent: :destroy
  has_many :entries, dependent: :nullify
  has_many :credit_notes, class_name: "Document", foreign_key: :credit_note_for_document_id,
    dependent: :restrict_with_exception
  has_many :debit_notes, class_name: "Document", foreign_key: :debit_note_for_document_id,
    dependent: :restrict_with_exception
  has_one :einvoice_submission, dependent: :restrict_with_exception
  has_one :eway_bill_submission, dependent: :restrict_with_exception
  has_many :procurement_matches, dependent: :destroy

  validates :tenant_id, :entity_id, :office_id, :doc_type, :fiscal_year,
    :document_date, :posting_date, presence: true
  validates :state, inclusion: { in: STATES }
  validate :document_type_matches_document
  validate :invoice_totals_are_consistent
  validate :contract_scope_is_valid
  validate :purchase_order_scope_is_valid

  def posted? = state == "posted"
  def postable? = %w[draft parked].include?(state)
  def reversible?
    posted? && reversed_by_document_id.nil? && !%w[CN PC PD RC PY RF].include?(doc_type) &&
      (!einvoice_submission || einvoice_submission.cancelled?) && !eway_bill_submission &&
      !settlement_activity? &&
      !credit_notes.where(state: %w[posted reversed]).exists? &&
      !debit_notes.where(state: %w[posted reversed]).exists?
  end

  def settlement_activity?
    return false unless posted_entry_id

    EntryLine.where(entry_id: posted_entry_id, open_item: true)
      .where("cleared_amount_minor > 0 OR cleared_on IS NOT NULL OR residual_of_line_id IS NOT NULL")
      .exists?
  end

  def statutory_printable?
    return false unless %w[SI CN].include?(doc_type)

    seller_fields = %w[legalName addressLine1 city postalCode stateCode countryCode identifier]
    customer_fields = %w[name addressLine1 city postalCode stateCode countryCode gstin]
    seller_fields.all? { |field| tax_registration_snapshot&.fetch(field, nil).present? } &&
      customer_fields.all? { |field| party_snapshot&.fetch(field, nil).present? }
  end

  def contains_goods?
    document_lines.any? { |line| line.item_snapshot&.fetch("itemType", nil) == "good" }
  end

  def eway_bill_required?
    contains_goods? && total_minor.to_i > Taxes::India::Gst::EwayBill::MANDATORY_THRESHOLD_MINOR
  end

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

  def contract_scope_is_valid
    return unless contract

    unless contract.tenant_id == tenant_id && contract.entity_id == entity_id &&
        contract.office_id == office_id && contract.party_id == party_id
      errors.add(:contract, "must belong to the same company, office, and customer")
    end
    errors.add(:contract, "must use the document currency") if currency && contract.currency != currency
  end


  def purchase_order_scope_is_valid
    return unless purchase_order

    unless doc_type == "PB" && purchase_order.tenant_id == tenant_id &&
        purchase_order.entity_id == entity_id && purchase_order.office_id == office_id &&
        purchase_order.vendor.id == party_id
      errors.add(:purchase_order, "must be an order for the same company, office, and vendor bill")
    end
  end
end
