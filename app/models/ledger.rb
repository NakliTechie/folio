# frozen_string_literal: true

# A ledger / valuation view. Balance is asserted per (entry, ledger), never globally.
# `PRIMARY` is seeded; extension ledgers (kind='extension') are modelled but unexposed in v1.
class Ledger < ApplicationRecord
  KINDS = %w[standard extension].freeze
  validates :tenant_id, :code, :name, presence: true
  validates :kind, inclusion: { in: KINDS }
end
