# frozen_string_literal: true

class ExchangeRate < ApplicationRecord
  RATE_TYPES = %w[spot closing average].freeze

  belongs_to :created_by, class_name: "User"
  has_many :exchange_revaluation_items, dependent: :restrict_with_exception

  normalizes :from_currency, :to_currency, with: ->(value) { value.to_s.strip.upcase }
  validates :tenant_id, :from_currency, :to_currency, :effective_on,
    :rate, :rate_type, :source, presence: true
  validates :from_currency, :to_currency, length: { is: 3 }
  validates :rate, numericality: { greater_than: 0 }
  validates :rate_type, inclusion: { in: RATE_TYPES }
  validates :effective_on, uniqueness: {
    scope: %i[tenant_id from_currency to_currency rate_type]
  }
  validate :currencies_are_distinct
  validate :creator_belongs_to_tenant
  validate :immutable_after_creation, on: :update

  private

  def currencies_are_distinct
    errors.add(:to_currency, "must differ from the source currency") if from_currency == to_currency
  end

  def creator_belongs_to_tenant
    return unless created_by && tenant_id
    return if created_by.memberships.exists?(tenant_id: tenant_id)

    errors.add(:created_by, "must belong to the company")
  end

  def immutable_after_creation
    errors.add(:base, "exchange rates are immutable; add a new effective date") if has_changes_to_save?
  end
end
