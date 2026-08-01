# frozen_string_literal: true

class AllocationRun < ApplicationRecord
  belongs_to :allocation_cycle
  belongs_to :created_by, class_name: "User"
  belongs_to :ledger_event, optional: true
  has_many :allocation_run_items, dependent: :restrict_with_exception

  validates :tenant_id, :idempotency_key, :request_sha256, :mode, :status,
    :period_start, :through_date, :posting_date, :allocated_amount_minor, :result, presence: true
  validates :idempotency_key, uniqueness: { scope: :tenant_id }
  validates :request_sha256, length: { is: 64 }
  validates :mode, inclusion: { in: %w[simulate post] }
  validates :status, inclusion: { in: %w[simulated posted] }
  validates :allocated_amount_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
