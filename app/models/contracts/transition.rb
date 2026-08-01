# frozen_string_literal: true

module Contracts
  module Transition
    ALLOWED = {
      "draft" => [ "signed" ],
      "signed" => [ "active" ],
      "active" => [ "closed" ],
      "closed" => []
    }.freeze
    EVENT_KINDS = {
      "signed" => "contract.signed",
      "active" => "contract.activated",
      "closed" => "contract.closed"
    }.freeze

    module_function

    def call(contract:, to:, actor:, occurred_on:)
      target = to.to_s
      on = parse_date!(occurred_on)
      Contract.transaction do
        contract.lock!
        unless ALLOWED.fetch(contract.status).include?(target)
          raise InvalidTransition, "contract cannot move from #{contract.status} to #{target}"
        end

        from = contract.status
        apply_transition!(contract, target, on)
        contract.save!
        DomainEvents::Record.call(
          tenant_id: contract.tenant_id,
          office_id: contract.office_id,
          kind: EVENT_KINDS.fetch(target),
          actor: "u:#{actor.id}",
          actor_user_id: actor.id,
          ref: contract.contract_number,
          payload: Contracts.event_payload(contract).merge(
            "fromStatus" => from, "toStatus" => target, "occurredOn" => on.iso8601
          )
        )
        contract
      end
    end

    def apply_transition!(contract, target, on)
      contract.status = target
      case target
      when "signed"
        contract.execution_date ||= on
        contract.signed_at = Time.current
        contract.signature_status = "signed"
        contract.approval_date ||= on
        contract.inception_date ||= on
      when "active"
        contract.effective_date ||= on
      when "closed"
        contract.closed_on = on
      end
    end

    def parse_date!(value)
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    rescue Date::Error
      raise InvalidTransition, "lifecycle date must be a valid ISO date"
    end
  end
end
