# frozen_string_literal: true

module MasterData
  module Audit
    module_function

    def append!(tenant_id:, actor:, action:, ref:, subject:, changes:)
      payload = { "subject" => subject, "changes" => changes }
      LedgerEvent.append!(
        tenant_id: tenant_id,
        actor: "u:#{actor.id}",
        actor_user_id: actor.id,
        action: action,
        origin: "folio",
        ts: Time.current.iso8601(6),
        ref: ref,
        payload_str: Folio::KhataHash.canonical_payload(payload)
      )
    end

    def lifecycle_action(prefix, changes)
      return "#{prefix}.deactivated" if changes.dig("active", "to") == false
      return "#{prefix}.reactivated" if changes.dig("active", "to") == true

      "#{prefix}.updated"
    end
  end
end
