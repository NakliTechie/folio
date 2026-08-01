# frozen_string_literal: true

class ExchangeRevaluationItem < ApplicationRecord
  belongs_to :exchange_revaluation_run
  belongs_to :exchange_rate

  validates :tenant_id, :account_code, :foreign_currency, :foreign_balance_minor,
    :carrying_functional_minor, :target_functional_minor, :difference_minor, presence: true
  validates :applied_rate, numericality: { greater_than: 0 }
  validates :account_code, uniqueness: {
    scope: %i[exchange_revaluation_run_id foreign_currency]
  }
  validates :foreign_currency, length: { is: 3 }
  validate :arithmetic_reconciles

  private

  def arithmetic_reconciles
    return if difference_minor == target_functional_minor - carrying_functional_minor

    errors.add(:difference_minor, "must reconcile target and carrying values")
  end
end
