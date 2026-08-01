# frozen_string_literal: true

module Contracts
  module PerformanceObligations
    module_function

    ATTRIBUTES = %i[
      description distinct series material_right satisfaction over_time_criterion
      progress_measure standalone_selling_price_minor ssp_method service_start_date
      service_end_date revenue_account_code
    ].freeze

    def create!(contract:, attributes:, actor:)
      Contract.transaction do
        contract.lock!
        raise InvalidContract, "performance obligations can only be added to a draft contract" unless contract.status == "draft"

        obligation = contract.contract_performance_obligations.create!(
          attributes.to_h.symbolize_keys.slice(*ATTRIBUTES).merge(
            tenant_id: contract.tenant_id,
            obligation_no: contract.contract_performance_obligations.maximum(:obligation_no).to_i + 1
          )
        )
        DomainEvents::Record.call(
          tenant_id: contract.tenant_id, office_id: contract.office_id,
          kind: "contract.performance_obligation_added", actor: "u:#{actor.id}",
          actor_user_id: actor.id, ref: contract.contract_number,
          payload: {
            "contractNumber" => contract.contract_number,
            "obligationNo" => obligation.obligation_no,
            "description" => obligation.description,
            "satisfaction" => obligation.satisfaction,
            "standaloneSellingPriceMinor" => obligation.standalone_selling_price_minor
          }
        )
        obligation
      end
    end
  end
end
