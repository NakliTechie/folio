# frozen_string_literal: true

# The parties spine. A single party may hold several roles (customer, vendor, employee).
# party_number is stable and human-meaningful so a .khata/Tally import keeps its codes.
class Party < ApplicationRecord
  has_many :party_roles, dependent: :restrict_with_exception
  has_many :party_tax_registrations, dependent: :restrict_with_exception

  normalizes :party_number, with: ->(number) { number.to_s.strip.upcase }
  normalizes :email, with: ->(email) { email.to_s.strip.downcase.presence }
  normalizes :country_code, with: ->(code) { code.to_s.strip.upcase }
  normalizes :state_code, with: ->(code) { code.to_s.strip.presence }

  validates :tenant_id, :party_number, :name, presence: true
  validates :party_number, uniqueness: { scope: :tenant_id }
  validates :country_code, length: { is: 2 }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validate :party_number_stays_immutable_after_use, on: :update

  scope :active, -> { where(active: true) }

  def role_codes = party_roles.order(:role).pluck(:role)

  def referenced?
    EntryLine.where(tenant_id: tenant_id, party_id: id).exists?
  end

  private

  def party_number_stays_immutable_after_use
    return unless will_save_change_to_party_number? && referenced?

    errors.add(:party_number, "cannot change after the party is referenced")
  end
end
