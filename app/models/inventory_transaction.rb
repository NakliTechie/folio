# frozen_string_literal: true

class InventoryTransaction < ApplicationRecord
  TYPES = %w[receipt issue transfer adjustment_in adjustment_out].freeze

  belongs_to :entity
  belongs_to :office
  belongs_to :created_by, class_name: "User"
  belongs_to :item
  belongs_to :source_warehouse, class_name: "Warehouse", optional: true
  belongs_to :destination_warehouse, class_name: "Warehouse", optional: true
  belongs_to :ledger_event
  has_many :inventory_movements, dependent: :restrict_with_exception

  validates :tenant_id, :idempotency_key, :request_sha256, :transaction_type,
    :posting_date, :quantity, :total_value_minor, :reason, presence: true
  validates :idempotency_key, uniqueness: { scope: :tenant_id }
  validates :request_sha256, length: { is: 64 }
  validates :transaction_type, inclusion: { in: TYPES }
  validates :quantity, numericality: { greater_than: 0 }
  validates :unit_cost_minor, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :total_value_minor, numericality: { only_integer: true, greater_than: 0 }
  validate :scope_matches

  private

  def scope_matches
    records = [ entity, office, item, source_warehouse, destination_warehouse, ledger_event ].compact
    errors.add(:base, "inventory transaction must stay within one company") unless
      records.all? { |record| record.tenant_id == tenant_id } &&
        created_by&.memberships&.exists?(tenant_id: tenant_id) &&
        office&.entity_id == entity_id && item&.item_type == "good"
  end
end
