# frozen_string_literal: true

class DepreciationRun < ApplicationRecord
  belongs_to :entity
  belongs_to :office
  belongs_to :created_by, class_name: "User"
  has_many :asset_transactions, dependent: :restrict_with_exception

  validates :tenant_id, :idempotency_key, :request_sha256, :mode, :status,
    :through_date, :posting_date, :result, presence: true
  validates :idempotency_key, uniqueness: { scope: :tenant_id }
  validates :request_sha256, length: { is: 64 }
  validates :mode, inclusion: { in: %w[simulate post] }
  validates :status, inclusion: { in: %w[simulated posted] }
end
