# frozen_string_literal: true

# A saleable/purchasable good or service. Rates and account-determination inputs are frozen into
# posted events later; the master remains the governed source for new drafts.
class Item < ApplicationRecord
  TYPES = %w[service good].freeze

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

  validates :tenant_id, :code, :name, :item_type, :hsn_sac_code, :unit_of_measure,
    :income_account_code, :expense_account_code, presence: true
  validates :code, uniqueness: { scope: :tenant_id }
  validates :item_type, inclusion: { in: TYPES }
  validates :hsn_sac_code, format: { with: /\A(?:\d{2}|\d{4}|\d{6}|\d{8})\z/ }
  validates :tax_rate_basis_points, numericality: { only_integer: true, in: 0..4000 }
  validates :cess_rate_basis_points, numericality: { only_integer: true, in: 0..10_000 }
  validate :gst_rate_splits_exactly
  validate :accounts_are_compatible
  validate :code_stays_immutable_after_use, on: :update

  scope :active, -> { where(active: true) }

  def referenced?
    EntryLine.where(tenant_id: tenant_id, item_id: id).exists?
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
    return unless will_save_change_to_code? && referenced?

    errors.add(:code, "cannot change after the item is referenced")
  end
end
