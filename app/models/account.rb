# frozen_string_literal: true

# A thin account master (B3.5, seed of the Batch 5/6 account master). `code` is the stable
# identifier; entry_lines reference it via account_code.
class Account < ApplicationRecord
  TYPES = %w[asset liability equity income expense].freeze
  validates :tenant_id, :code, :name, :account_type, presence: true
  validates :code, uniqueness: { scope: :tenant_id }
  validates :account_type, inclusion: { in: TYPES }
end
