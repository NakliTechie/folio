# frozen_string_literal: true

class GoodsReceipt < ApplicationRecord
  belongs_to :purchase_order
  belongs_to :created_by, class_name: "User"
  has_many :goods_receipt_lines, dependent: :restrict_with_exception

  validates :tenant_id, :receipt_number, :idempotency_key, :request_sha256, :received_on, presence: true
  validates :receipt_number, :idempotency_key, uniqueness: { scope: :tenant_id }
  validate :scope_matches

  private

  def scope_matches
    errors.add(:base, "goods receipt must stay within one company") unless
      purchase_order&.tenant_id == tenant_id && created_by&.memberships&.exists?(tenant_id: tenant_id)
  end
end
