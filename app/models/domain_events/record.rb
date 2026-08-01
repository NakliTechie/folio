# frozen_string_literal: true

module DomainEvents
  # The module-facing entry point for appending to the non-financial log.
  #
  # A module (contract management, procurement, …) calls Record.call with a registered
  # kind and a plain Ruby payload; this canonicalises the payload and appends the chain
  # link. It mirrors MasterData::Audit#append! (the equivalent thin producer over
  # ledger_events) so the two logs are produced the same way.
  #
  # Fail-fast on an unknown kind BEFORE touching the database, with a precise error —
  # the model's inclusion validation is the backstop, but a producer deserves the clear
  # message at the call site rather than a generic RecordInvalid.
  module Record
    module_function

    # Returns the appended DomainEvent. `payload` is a plain Hash; it is canonicalised
    # here (never pre-serialise it — that is the classic way to fork the chain). `ts`
    # defaults to now in microsecond ISO8601, matching MasterData::Audit.
    def call(tenant_id:, kind:, actor:, payload:, ref: nil, office_id: nil,
             actor_user_id: nil, origin: "folio", ts: nil)
      raise DomainEvents::UnknownKind, kind unless DomainEvents::Kinds.valid?(kind)

      DomainEvent.append!(
        tenant_id: tenant_id,
        actor: actor,
        action: kind,
        origin: origin,
        ts: ts || Time.current.iso8601(6),
        ref: ref,
        office_id: office_id,
        actor_user_id: actor_user_id,
        payload_str: Folio::KhataHash.canonical_payload(payload)
      )
    end
  end
end
