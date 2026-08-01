# frozen_string_literal: true

class PurchaseOrder < ApplicationRecord
  STATUSES = %w[draft approved partially_received received closed].freeze

  belongs_to :entity
  belongs_to :office
  belongs_to :vendor_profile
  belongs_to :created_by, class_name: "User"
  belongs_to :approved_by, class_name: "User", optional: true
  has_many :purchase_order_lines, dependent: :restrict_with_exception
  has_many :goods_receipts, dependent: :restrict_with_exception
  has_many :procurement_matches, dependent: :restrict_with_exception

  validates :tenant_id, :order_number, :fiscal_year, :status, :order_date,
    :currency, :minor_unit_exponent, :subtotal_minor, presence: true
  validates :order_number, uniqueness: { scope: :tenant_id }
  validates :status, inclusion: { in: STATUSES }
  validates :subtotal_minor, numericality: { only_integer: true, greater_than: 0 }
  validate :scope_matches
  validate :approval_is_coherent

  scope :open_for_receipt, -> { where(status: %w[approved partially_received]) }

  def vendor
    vendor_profile.party
  end

  def receivable?
    %w[approved partially_received].include?(status)
  end

  private

  def scope_matches
    errors.add(:base, "purchase order must stay within one company and office") unless
      entity&.tenant_id == tenant_id && office&.tenant_id == tenant_id &&
        office&.entity_id == entity_id && vendor_profile&.tenant_id == tenant_id &&
        created_by&.memberships&.exists?(tenant_id: tenant_id) &&
        (!approved_by || approved_by.memberships.exists?(tenant_id: tenant_id))
  end

  def approval_is_coherent
    approved = status != "draft"
    errors.add(:base, "released purchase order requires approval evidence") if
      approved && (approved_by_id.blank? || approved_at.blank?)
  end
end
