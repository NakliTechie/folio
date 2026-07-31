# frozen_string_literal: true

module OpenItemCredits
  InvalidCreditAction = Class.new(ArgumentError)

  CONFIG = {
    "customer" => { account_code: "1200", normal_sign: 1 },
    "vendor" => { account_code: "2000", normal_sign: -1 }
  }.freeze

  module_function

  def transaction_amount(line)
    line.amounts.find { |amount| amount.slot_role == "transaction" }&.amount_minor.to_i
  end

  def credit?(line, role: line&.party_role)
    config = CONFIG[role.to_s]
    config && eligible_base?(line, config) && transaction_amount(line) * config.fetch(:normal_sign) < 0
  end

  def target?(line, role: line&.party_role)
    config = CONFIG[role.to_s]
    config && eligible_base?(line, config) && transaction_amount(line) * config.fetch(:normal_sign) > 0
  end

  def eligible_base?(line, config)
    line&.open_item? && line.cleared_on.nil? && line.source_event_id.present? &&
      line.account_code == config.fetch(:account_code) && line.party_id.present? &&
      Posting::Clearing.open_amount(line).positive?
  end
end
