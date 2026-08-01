# frozen_string_literal: true

class AssetClass < ApplicationRecord
  ACCOUNT_FIELDS = %i[
    apc_account_code accumulated_depreciation_account_code depreciation_expense_account_code
    gain_account_code loss_account_code
  ].freeze

  has_many :fixed_assets, dependent: :restrict_with_exception

  normalizes :code, with: ->(value) { value.to_s.strip.upcase }
  ACCOUNT_FIELDS.each { |field| normalizes field, with: ->(value) { value.to_s.strip } }

  validates :tenant_id, :code, :name, :default_useful_life_months, *ACCOUNT_FIELDS, presence: true
  validates :code, uniqueness: { scope: :tenant_id }
  validates :default_useful_life_months, numericality: { only_integer: true, greater_than: 0 }
  validate :accounts_are_compatible

  scope :active, -> { where(active: true) }

  private

  def accounts_are_compatible
    validate_account(:apc_account_code, "asset")
    validate_account(:accumulated_depreciation_account_code, "asset")
    validate_account(:depreciation_expense_account_code, "expense")
    validate_account(:gain_account_code, "income")
    validate_account(:loss_account_code, "expense")
  end

  def validate_account(attribute, expected_type)
    code = public_send(attribute)
    return if code.blank?

    account = Account.active.find_by(tenant_id: tenant_id, code: code)
    errors.add(attribute, "must be an active #{expected_type} account in this company") unless
      account&.account_type == expected_type
  end
end
