# frozen_string_literal: true

class AssetTransaction < ApplicationRecord
  TYPES = %w[acquisition depreciation].freeze

  belongs_to :fixed_asset
  belongs_to :asset_valuation
  belongs_to :depreciation_run, optional: true
  belongs_to :created_by, class_name: "User"
  belongs_to :ledger_event, optional: true

  validates :tenant_id, :idempotency_key, :transaction_type, :valuation_code,
    :asset_value_date, :posting_date, :amount_minor, :details, presence: true
  validates :idempotency_key, uniqueness: { scope: %i[tenant_id valuation_code] }
  validates :transaction_type, inclusion: { in: TYPES }
  validates :valuation_code, inclusion: { in: AssetValuationTerm::CODES }
  validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
  validate :scope_matches

  private

  def scope_matches
    records = [ fixed_asset, asset_valuation, depreciation_run, ledger_event ].compact
    errors.add(:base, "asset transaction must stay within one company and valuation view") unless
      records.all? { |record| record.tenant_id == tenant_id } &&
        asset_valuation&.fixed_asset_id == fixed_asset_id &&
        asset_valuation&.valuation_code == valuation_code &&
        created_by&.memberships&.exists?(tenant_id: tenant_id) &&
        ledger_event.present? == asset_valuation&.posts_to_ledger
  end
end
