# frozen_string_literal: true

# A place, belonging to an entity. Carries no GSTIN — registrations live in
# tax_registrations, because one office may hold several and many offices may share one.
class Office < ApplicationRecord
  belongs_to :entity
  has_many :office_tax_registrations, dependent: :restrict_with_exception
  has_many :tax_registrations, through: :office_tax_registrations
  validates :tenant_id, :code, :name, presence: true
  validates :country_code, length: { is: 2 }, allow_blank: true
  validates :postal_code, format: { with: /\A\d{6}\z/ }, allow_blank: true,
    if: -> { country_code == "IN" }
  validate :india_state_code_is_valid

  normalizes :country_code, with: ->(code) { code.to_s.strip.upcase.presence }
  normalizes :state_code, with: ->(code) { code.to_s.strip.presence }
  normalizes :postal_code, with: ->(code) { code.to_s.gsub(/\s+/, "").presence }

  def statutory_address_complete?
    [ address_line1, city, postal_code, state_code, country_code ].all?(&:present?)
  end

  private

  def india_state_code_is_valid
    return if state_code.blank? || entity&.jurisdiction_profile != "IN"
    return if Taxes::India::StateCodes.valid?(state_code)

    errors.add(:state_code, "must be a valid GST state code")
  end
end
