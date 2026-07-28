# frozen_string_literal: true

# Document identity + lifecycle (spec §7, §8). The IDENTITY object plus the draft → parked →
# posted → reversed lifecycle. external_reference drives duplicate-invoice detection;
# document_number is allocated from a NumberRange (never a Postgres sequence) inside the
# posting transaction. A document type declares how it posts — the core stays generic.
class Document < ApplicationRecord
  STATES = %w[draft parked posted reversed].freeze

  belongs_to :document_type, optional: true
  belongs_to :reverses, class_name: "Document", foreign_key: :reverses_document_id, optional: true
  belongs_to :reversed_by, class_name: "Document", foreign_key: :reversed_by_document_id, optional: true
  has_many :document_lines, -> { order(:line_no) }, dependent: :destroy
  has_many :entries, dependent: :nullify

  validates :tenant_id, :entity_id, :office_id, :doc_type, :fiscal_year, presence: true
  validates :state, inclusion: { in: STATES }

  def posted? = state == "posted"
  def postable? = %w[draft parked].include?(state)
  def reversible? = posted? && reversed_by_document_id.nil?
end
