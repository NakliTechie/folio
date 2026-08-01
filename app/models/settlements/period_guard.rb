# frozen_string_literal: true

module Settlements
  # Clearing corrections change the projection of already-posted open items. They therefore
  # honor the period control of every affected source line, even though they append a clearing
  # event rather than a new accounting entry.
  module PeriodGuard
    module_function

    def assert_mutable!(lines:, user:)
      Array(lines).compact.uniq { |line| [ line.source_event_id, line.ledger_id, line.line_no ] }.each do |line|
        entry = line.entry
        account_class = Posting::PostEntry.account_class_for(party_role: line.party_role)
        state, capability = PeriodControl.resolve(
          tenant_id: line.tenant_id, entity_id: line.entity_id, ledger_id: line.ledger_id,
          account_class: account_class, fiscal_year: entry.fiscal_year, period_no: entry.period_no
        )

        if state == "closed"
          raise InvalidReset,
            "period #{entry.fiscal_year}/#{entry.period_no} is closed for #{account_class}; reopen it before changing this allocation"
        end
        next unless state == "restricted"
        next if capability && user && Authorization.permits?(
          user: user, tenant_id: line.tenant_id, office_id: line.office_id, capability: capability
        )

        raise InvalidReset,
          "period #{entry.fiscal_year}/#{entry.period_no} is restricted; capability '#{capability}' is required to change this allocation"
      end
    end
  end
end
