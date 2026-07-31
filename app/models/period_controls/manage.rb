# frozen_string_literal: true

module PeriodControls
  module Manage
    STATES = PeriodControl::STATES.freeze
    RESTRICTED_CAPABILITY = "period.lock"

    module_function

    def call(tenant:, fiscal_year:, period_no:, state:, actor:)
      unless Authorization.permits?(user: actor, tenant_id: tenant.id, capability: RESTRICTED_CAPABILITY)
        raise InvalidControl, "not permitted to change period controls"
      end

      fiscal_year = Integer(fiscal_year)
      period_no = Integer(period_no)
      state = state.to_s
      raise InvalidControl, "choose open, restricted, or closed" unless STATES.include?(state)
      raise InvalidControl, "period must be between 0 and 16" unless (0..16).cover?(period_no)
      raise InvalidControl, "fiscal year must be between 1900 and 9998" unless (1900..9998).cover?(fiscal_year)

      entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      ledger = Ledger.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      PeriodControl.transaction do
        scope = scope_for(tenant, entity, ledger, fiscal_year, period_no)
        existing = PeriodControl.find_by(scope)
        return PeriodControl.new(scope.merge(state: "open")) if existing.nil? && state == "open"

        control = existing || PeriodControl.find_or_create_by!(scope)
        control.lock!
        previous = { "state" => control.state, "capability" => control.capability }
        control.assign_attributes(
          state: state,
          capability: state == "restricted" ? RESTRICTED_CAPABILITY : nil
        )
        return control unless control.changed?

        control.save!
        append_event!(control, previous: previous, actor: actor)
        control
      end
    rescue ArgumentError, TypeError
      raise InvalidControl, "fiscal year and period must be valid numbers"
    end

    def scope_for(tenant, entity, ledger, fiscal_year, period_no)
      {
        tenant_id: tenant.id,
        entity_id: entity.id,
        ledger_id: ledger.id,
        account_class: PeriodControl::WILDCARD,
        fiscal_year: fiscal_year,
        period_no: period_no,
        domain: "posting"
      }
    end

    def append_event!(control, previous:, actor:)
      current = { "state" => control.state, "capability" => control.capability }
      payload = {
        "periodControl" => {
          "entityId" => control.entity_id,
          "ledgerId" => control.ledger_id,
          "accountClass" => control.account_class,
          "fiscalYear" => control.fiscal_year,
          "periodNo" => control.period_no,
          "domain" => control.domain
        },
        "changes" => { "from" => previous, "to" => current }
      }
      LedgerEvent.append!(
        tenant_id: control.tenant_id,
        actor: "u:#{actor.id}",
        actor_user_id: actor.id,
        action: "period.#{control.state}",
        origin: "folio",
        ts: Time.current.iso8601(6),
        ref: "period:#{control.entity_id}:#{control.ledger_id}:#{control.fiscal_year}:#{control.period_no}",
        payload_str: Folio::KhataHash.canonical_payload(payload)
      )
    end
  end
end
