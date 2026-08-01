# frozen_string_literal: true

class VendorProfile < ApplicationRecord
  belongs_to :party
  belongs_to :created_by, class_name: "User"
  belongs_to :approved_by, class_name: "User", optional: true
  has_many :purchase_orders, dependent: :restrict_with_exception

  normalizes :preferred_currency, with: ->(currency) { currency.to_s.upcase }

  validates :tenant_id, :status, :payment_terms_days, :preferred_currency, presence: true
  validates :party_id, uniqueness: { scope: :tenant_id }
  validates :status, inclusion: { in: %w[pending approved suspended] }
  validates :payment_terms_days, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :preferred_currency, length: { is: 3 }
  validate :scope_matches
  validate :approval_is_coherent
  validate :currency_is_supported

  scope :approved, -> { where(status: "approved", spend_authorized: true) }

  def orderable?
    status == "approved" && spend_authorized? && !purchasing_hold?
  end

  private

  def scope_matches
    errors.add(:base, "vendor profile must stay within one company and vendor party") unless
      party&.tenant_id == tenant_id && party&.role_codes&.include?("vendor") &&
        created_by&.memberships&.exists?(tenant_id: tenant_id) &&
        (!approved_by || approved_by.memberships.exists?(tenant_id: tenant_id))
  end

  def approval_is_coherent
    approved = status == "approved"
    errors.add(:base, "approved vendor requires spend authority and independent approval evidence") unless
      approved == (spend_authorized? && approved_by_id.present? && approved_at.present?)
  end

  def currency_is_supported
    CurrencyProfile.exponent_for!(preferred_currency)
  rescue CurrencyProfile::UnsupportedCurrency => e
    errors.add(:preferred_currency, e.message)
  end
end
