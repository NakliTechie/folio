# frozen_string_literal: true

class AssetValuationTerm < ApplicationRecord
  CODES = %w[BOOK TAX_IT].freeze
  METHODS = %w[straight_line].freeze

  belongs_to :fixed_asset
  belongs_to :created_by, class_name: "User"
  belongs_to :created_domain_event, class_name: "DomainEvent"
  has_one :asset_valuation, dependent: :restrict_with_exception

  validates :tenant_id, :valuation_code, :depreciation_method, :useful_life_months,
    :residual_value_minor, :depreciation_start_date, :valid_from, presence: true
  validates :valuation_code, inclusion: { in: CODES }
  validates :depreciation_method, inclusion: { in: METHODS }
  validates :useful_life_months, numericality: { only_integer: true, greater_than: 0 }
  validates :residual_value_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :scope_matches
  validate :date_range_is_valid

  scope :current, -> { where(valid_to: nil) }

  private

  def scope_matches
    errors.add(:base, "valuation terms must stay within one company") unless
      fixed_asset&.tenant_id == tenant_id && created_domain_event&.tenant_id == tenant_id &&
        created_by&.memberships&.exists?(tenant_id: tenant_id)
  end

  def date_range_is_valid
    errors.add(:valid_to, "cannot be before valid from") if valid_to && valid_from && valid_to < valid_from
  end
end
