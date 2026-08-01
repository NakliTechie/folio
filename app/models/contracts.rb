# frozen_string_literal: true

module Contracts
  InvalidContract = Class.new(StandardError)
  InvalidTransition = Class.new(InvalidContract)

  module_function

  def fiscal_year(date, variant:)
    Documents.fiscal_year(date, variant: variant)
  end

  def format_number(fiscal_year, sequence)
    "CTR/#{fiscal_year.to_s.last(2)}-#{(fiscal_year + 1).to_s.last(2)}/#{sequence.to_s.rjust(5, '0')}"
  end

  def event_payload(contract)
    {
      "contractId" => contract.id,
      "contractNumber" => contract.contract_number,
      "title" => contract.title,
      "side" => contract.side,
      "status" => contract.status,
      "partyId" => contract.party_id,
      "officeId" => contract.office_id,
      "currency" => contract.currency,
      "totalContractValueMinor" => contract.total_contract_value_minor
    }
  end
end
