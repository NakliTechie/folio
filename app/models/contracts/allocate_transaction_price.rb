# frozen_string_literal: true

module Contracts
  module AllocateTransactionPrice
    module_function

    def call(contract:, actor:, effective_date:, trigger: "initial")
      unless trigger.to_s == "initial"
        raise InvalidContract, "contract modifications are not supported in this release"
      end

      Contract.transaction do
        contract.lock!
        if contract.contract_allocation_runs.exists?
          raise InvalidContract,
            "transaction price is already allocated; contract modifications are not supported in this release"
        end
        obligations = contract.contract_performance_obligations.in_number_order.lock.to_a
        raise InvalidContract, "add at least one performance obligation before allocating" if obligations.empty?

        total_ssp = obligations.sum(&:standalone_selling_price_minor)
        raise InvalidContract, "the total standalone selling price must be greater than zero" unless total_ssp.positive?

        version = 1
        allocations = allocate_exactly(contract.total_contract_value_minor, obligations, total_ssp)
        event = DomainEvents::Record.call(
          tenant_id: contract.tenant_id, office_id: contract.office_id,
          kind: "contract.transaction_price_allocated", actor: "u:#{actor.id}",
          actor_user_id: actor.id, ref: contract.contract_number,
          payload: {
            "contractNumber" => contract.contract_number, "version" => version,
            "method" => "relative_ssp", "transactionPriceMinor" => contract.total_contract_value_minor,
            "totalStandaloneSellingPriceMinor" => total_ssp,
            "allocations" => allocations.map do |obligation, amount|
              { "obligationNo" => obligation.obligation_no, "allocatedPriceMinor" => amount }
            end
          }
        )
        run = contract.contract_allocation_runs.create!(
          tenant_id: contract.tenant_id, created_domain_event: event, version: version,
          effective_date: effective_date, method: "relative_ssp", trigger: trigger,
          transaction_price_minor: contract.total_contract_value_minor, total_ssp_minor: total_ssp
        )
        allocations.each do |obligation, amount|
          run.contract_allocation_lines.create!(
            tenant_id: contract.tenant_id, contract_performance_obligation: obligation,
            standalone_selling_price_minor: obligation.standalone_selling_price_minor,
            allocation_ratio: BigDecimal(obligation.standalone_selling_price_minor.to_s) / total_ssp,
            allocated_price_minor: amount
          )
        end
        run
      end
    end

    # Largest-remainder allocation: exact to the minor unit, deterministic, and fair even
    # when the transaction price cannot be divided by the SSP ratios without a remainder.
    def allocate_exactly(transaction_price, obligations, total_ssp)
      shares = obligations.map do |obligation|
        numerator = transaction_price * obligation.standalone_selling_price_minor
        [ obligation, numerator / total_ssp, numerator % total_ssp ]
      end
      residual = transaction_price - shares.sum { |_, floor, _| floor }
      winners = shares.sort_by { |obligation, _, remainder| [ -remainder, obligation.obligation_no ] }
        .first(residual).to_h { |obligation, _, _| [ obligation.id, true ] }
      shares.to_h { |obligation, floor, _| [ obligation, floor + (winners[obligation.id] ? 1 : 0) ] }
    end
  end
end
