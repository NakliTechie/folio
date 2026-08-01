# frozen_string_literal: true

# A saleable/purchasable good or service. Rates and account-determination inputs are frozen into
# posted events later; the master remains the governed source for new drafts.
class Item < ApplicationRecord
  TYPES = %w[service good].freeze
  INVENTORY_CLASSES = %w[raw_material wip finished_good trading].freeze
  VALUATION_METHODS = %w[moving_average].freeze

  def tax_rate
    @tax_rate || tax_rate_basis_points.to_d / 100
  end

  def tax_rate=(value)
    @tax_rate = value
  end

  def cess_rate
    @cess_rate || cess_rate_basis_points.to_d / 100
  end

  def cess_rate=(value)
    @cess_rate = value
  end

  normalizes :code, with: ->(code) { code.to_s.strip.upcase }
  normalizes :hsn_sac_code, with: ->(code) { code.to_s.gsub(/\s+/, "") }
  normalizes :unit_of_measure, with: ->(unit) { unit.to_s.strip.upcase }
  normalizes :income_account_code, with: ->(code) { code.to_s.strip }
  normalizes :expense_account_code, with: ->(code) { code.to_s.strip }
  normalizes :inventory_account_code, with: ->(code) { code.to_s.strip.presence }
  normalizes :revision, with: ->(revision) { revision.to_s.strip.upcase.presence }
  normalizes :inventory_class, with: ->(value) { value.to_s.strip.presence }
  normalizes :valuation_method, with: ->(value) { value.to_s.strip.presence }

  validates :tenant_id, :code, :name, :item_type, :hsn_sac_code, :unit_of_measure,
    :income_account_code, :expense_account_code, presence: true
  validates :code, uniqueness: { scope: :tenant_id }
  validates :item_type, inclusion: { in: TYPES }
  validates :inventory_class, inclusion: { in: INVENTORY_CLASSES }, if: :good?
  validates :valuation_method, inclusion: { in: VALUATION_METHODS }, if: :good?
  validates :revision, :inventory_account_code, presence: true, if: :good?
  validates :inventory_class, :valuation_method, :revision, :inventory_account_code,
    absence: true, if: :service?
  validates :hsn_sac_code, format: { with: /\A(?:\d{2}|\d{4}|\d{6}|\d{8})\z/ }
  validates :tax_rate_basis_points, numericality: { only_integer: true, in: 0..4000 }
  validates :cess_rate_basis_points, numericality: { only_integer: true, in: 0..10_000 }
  validate :gst_rate_splits_exactly
  validate :accounts_are_compatible
  validate :code_stays_immutable_after_use, on: :update
  validate :inventory_settings_stay_immutable_after_use, on: :update

  scope :active, -> { where(active: true) }

  def referenced?
    EntryLine.where(tenant_id: tenant_id, item_id: id).exists?
  end

  def good?
    item_type == "good"
  end

  def service?
    item_type == "service"
  end

  private

  # The current India posting model stores CGST and SGST/UTGST rates as whole basis
  # points. An odd total rate cannot be represented exactly as two components, so reject
  # it at the governed master instead of allowing drafts that fail only at posting.
  def gst_rate_splits_exactly
    return unless tax_rate_basis_points.is_a?(Integer) && tax_rate_basis_points.odd?

    errors.add(:tax_rate_basis_points, "must split exactly into equal GST components")
  end

  def accounts_are_compatible
    validate_account(:income_account_code, "income")
    validate_account(:expense_account_code, "expense")
    validate_account(:inventory_account_code, "asset") if good?
  end

  def validate_account(attribute, expected_type)
    code = public_send(attribute)
    return if code.blank?

    account = Account.find_by(tenant_id: tenant_id, code: code, active: true)
    unless account&.account_type == expected_type
      errors.add(attribute, "must name an active #{expected_type} account in this company")
    end
  end

  def code_stays_immutable_after_use
    return unless (will_save_change_to_code? || will_save_change_to_item_type?) && referenced?

    errors.add(:base, "item code and type cannot change after the item is referenced")
  end

  def inventory_settings_stay_immutable_after_use
    return unless InventoryMovement.where(tenant_id: tenant_id, item_id: id).exists?

    stable = %w[inventory_class valuation_method inventory_account_code]
    return unless stable.any? { |attribute| will_save_change_to_attribute?(attribute) }

    errors.add(:base, "inventory class, valuation method, and asset account are locked after movement")
  end
end
