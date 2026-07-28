# frozen_string_literal: true

# An effective-dated tax registration (GSTIN/TAN/ISD/VAT/EIN/SST). A historical document
# keeps the registration in force at its posting date, so valid_from/valid_to matter.
# Every Indian statutory return files per registration.
class TaxRegistration < ApplicationRecord
  belongs_to :entity
  KINDS = %w[GSTIN TAN ISD VAT EIN SST].freeze
  validates :tenant_id, :kind, :identifier, presence: true
  validates :kind, inclusion: { in: KINDS }

  # In force on a given date (nil bounds are open).
  scope :in_force_on, ->(date) {
    where("valid_from IS NULL OR valid_from <= ?", date)
      .where("valid_to IS NULL OR valid_to >= ?", date)
  }
end
