# frozen_string_literal: true

# Period control (spec §6, D6). Scoped by (entity, ledger, account_class, fiscal_year,
# period_no, domain); resolves to open / restricted / closed. `restricted` requires a named
# capability. account_class "ALL" is the wildcard; a specific class wins over it.
class PeriodControl < ApplicationRecord
  STATES = %w[open restricted closed].freeze
  DOMAINS = %w[posting tax inventory].freeze
  WILDCARD = "ALL"

  validates :tenant_id, :entity_id, :ledger_id, :account_class, :fiscal_year, :period_no, presence: true
  validates :state, inclusion: { in: STATES }
  validates :domain, inclusion: { in: DOMAINS }
  validates :period_no, inclusion: { in: 0..16 }
  validates :capability, presence: true, if: -> { state == "restricted" }

  # The effective control for a post: the specific account_class wins, else the ALL
  # wildcard, else open. Returns [state, capability].
  def self.resolve(tenant_id:, entity_id:, ledger_id:, account_class:, fiscal_year:, period_no:, domain: "posting")
    base = where(tenant_id: tenant_id, entity_id: entity_id, ledger_id: ledger_id,
                 fiscal_year: fiscal_year, period_no: period_no, domain: domain)
    row = base.find_by(account_class: account_class) || base.find_by(account_class: WILDCARD)
    row ? [ row.state, row.capability ] : [ "open", nil ]
  end
end
