# frozen_string_literal: true

module Contracts
  module Update
    ATTRIBUTES = Contracts::Create::ATTRIBUTES.freeze

    module_function

    def call(contract:, attributes:, actor:)
      Contract.transaction do
        contract.lock!
        raise InvalidContract, "only a draft contract can be edited" unless contract.status == "draft"
        if contract.contract_allocation_runs.exists?
          raise InvalidContract,
            "allocated contract terms are frozen; create a replacement contract for changed terms"
        end

        contract.assign_attributes(attributes.to_h.symbolize_keys.slice(*ATTRIBUTES))
        changes = contract.changes.transform_values { |before, after| { "from" => before, "to" => after } }
        return contract if changes.empty?

        contract.save!
        DomainEvents::Record.call(
          tenant_id: contract.tenant_id,
          office_id: contract.office_id,
          kind: "contract.updated",
          actor: "u:#{actor.id}",
          actor_user_id: actor.id,
          ref: contract.contract_number,
          payload: Contracts.event_payload(contract).merge("changes" => changes)
        )
        contract
      end
    end
  end
end
