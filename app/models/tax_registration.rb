# frozen_string_literal: true

# An effective-dated tax registration (GSTIN/TAN/ISD/VAT/EIN/SST). A historical document
# keeps the registration in force at its posting date, so valid_from/valid_to matter.
# Every Indian statutory return files per registration.
class TaxRegistration < ApplicationRecord
  belongs_to :entity
  has_many :office_tax_registrations, dependent: :restrict_with_exception
  has_many :offices, through: :office_tax_registrations

  KINDS = %w[GSTIN TAN ISD VAT EIN SST].freeze

  normalizes :kind, with: ->(kind) { kind.to_s.upcase }
  normalizes :identifier, with: ->(identifier) { identifier.to_s.strip.upcase }

  validates :tenant_id, :kind, :identifier, :valid_from, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :identifier, uniqueness: { scope: %i[tenant_id kind valid_from] }
  validate :entity_belongs_to_tenant
  validate :valid_dates_are_ordered
  validate :registration_kind_matches_profile
  validate :gstin_is_valid
  validate :stable_identity_after_use, on: :update

  before_validation :derive_gstin_state

  # In force on a given date (nil bounds are open).
  scope :active, -> { where(active: true) }
  scope :in_force_on, ->(date) {
    active.where("valid_from IS NULL OR valid_from <= ?", date)
      .where("valid_to IS NULL OR valid_to >= ?", date)
  }

  def referenced?
    EntryLine.where(tenant_id: tenant_id, tax_registration_id: id).exists?
  end

  private

  def entity_belongs_to_tenant
    errors.add(:entity, "must belong to the same tenant") if entity && entity.tenant_id != tenant_id
  end

  def valid_dates_are_ordered
    return if valid_from.blank? || valid_to.blank? || valid_to >= valid_from

    errors.add(:valid_to, "must be on or after valid from")
  end

  def registration_kind_matches_profile
    return unless entity

    allowed = Jurisdictions.fetch!(entity.jurisdiction_profile).registration_kinds
    errors.add(:kind, "is not valid for #{entity.jurisdiction_profile}") unless allowed.include?(kind)
  rescue Jurisdictions::UnsupportedProfile
    errors.add(:kind, "cannot be resolved for the entity jurisdiction")
  end

  def gstin_is_valid
    return unless kind == "GSTIN"
    return if Taxes::India::Gstin.valid?(identifier)

    errors.add(:identifier, "is not a valid GSTIN")
  end

  def derive_gstin_state
    self.state_code = Taxes::India::Gstin.state_code(identifier) if kind == "GSTIN"
  end

  def stable_identity_after_use
    return unless referenced?

    changed = %w[entity_id kind identifier state_code valid_from].any? { |field| will_save_change_to_attribute?(field) }
    errors.add(:base, "a referenced registration's identity and effective start are immutable") if changed
  end
end
