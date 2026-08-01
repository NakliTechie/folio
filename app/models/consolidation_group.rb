# frozen_string_literal: true

class ConsolidationGroup < ApplicationRecord
  belongs_to :created_by, class_name: "User"
  has_many :consolidation_group_members, dependent: :restrict_with_exception
  has_many :entities, through: :consolidation_group_members
  has_many :intercompany_transactions, dependent: :restrict_with_exception
  has_many :consolidation_elimination_runs, dependent: :restrict_with_exception

  normalizes :code, with: ->(code) { code.to_s.strip.upcase }
  normalizes :presentation_currency, with: ->(currency) { currency.to_s.strip.upcase }
  validates :tenant_id, :code, :name, :presentation_currency, presence: true
  validates :code, uniqueness: { scope: :tenant_id }, format: { with: /\A[A-Z0-9_-]+\z/ }
  validates :presentation_currency, length: { is: 3 }
  validate :creator_belongs_to_company
  validate :currency_is_supported

  private

  def creator_belongs_to_company
    errors.add(:created_by, "must belong to the company") unless
      created_by&.memberships&.exists?(tenant_id: tenant_id)
  end

  def currency_is_supported
    CurrencyProfile.exponent_for!(presentation_currency)
  rescue CurrencyProfile::UnsupportedCurrency => e
    errors.add(:presentation_currency, e.message)
  end
end
