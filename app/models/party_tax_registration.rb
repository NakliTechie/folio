# frozen_string_literal: true

class PartyTaxRegistration < ApplicationRecord
  KINDS = %w[GSTIN].freeze

  belongs_to :party

  normalizes :kind, with: ->(kind) { kind.to_s.upcase }
  normalizes :identifier, with: ->(identifier) { identifier.to_s.strip.upcase }

  validates :tenant_id, :kind, :identifier, :valid_from, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :identifier, uniqueness: { scope: %i[tenant_id kind valid_from] }
  validate :party_belongs_to_tenant
  validate :valid_dates_are_ordered
  validate :gstin_is_valid
  validate :effective_period_does_not_overlap

  scope :active, -> { where(active: true) }
  scope :in_force_on, lambda { |date|
    active.where("valid_from IS NULL OR valid_from <= ?", date)
      .where("valid_to IS NULL OR valid_to >= ?", date)
  }

  before_validation :derive_gstin_state

  private

  def party_belongs_to_tenant
    errors.add(:party, "must belong to the same tenant") if party && party.tenant_id != tenant_id
  end

  def valid_dates_are_ordered
    return if valid_from.blank? || valid_to.blank? || valid_to >= valid_from

    errors.add(:valid_to, "must be on or after valid from")
  end

  def gstin_is_valid
    return unless kind == "GSTIN"
    return if Taxes::India::Gstin.valid?(identifier)

    errors.add(:identifier, "is not a valid GSTIN")
  end

  def effective_period_does_not_overlap
    return unless active? && party_id.present? && kind.present? && valid_from.present?

    finish = valid_to || Date.new(9999, 12, 31)
    overlap = self.class.where(party_id: party_id, kind: kind, active: true)
      .where.not(id: id)
      .where("valid_from <= ? AND (valid_to IS NULL OR valid_to >= ?)", finish, valid_from)
      .exists?
    errors.add(:base, "GST registration effective dates overlap another active registration") if overlap
  end

  def derive_gstin_state
    self.state_code = Taxes::India::Gstin.state_code(identifier) if kind == "GSTIN"
  end
end
