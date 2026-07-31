# frozen_string_literal: true

module Settlements
  module ResetAllocation
    module_function

    def call(document:, allocation_id:, actor:, reset_on: Date.current)
      ActiveRecord::Base.transaction do
        document.lock!
        unless %w[RC PY].include?(document.doc_type) && document.state == "posted"
          raise InvalidReset, "only a posted receipt or payment allocation can be reset"
        end
        raise InvalidReset, "reset date cannot precede the settlement" if reset_on < document.document_date
        allocation = document.document_allocations.lock.find(allocation_id)
        unless allocation.applied? && allocation.settlement_reallocation.nil?
          raise InvalidReset, "allocation is not currently applied"
        end

        target_event = clearing_event!(document, allocation.target_clearing_event_id)
        settlement_event = clearing_event!(document, allocation.settlement_clearing_event_id)
        target_reset = Posting::Clearing.reset!(
          clearing_event: target_event, actor: actor, reset_on: reset_on,
          reason: "reset #{document.doc_type.downcase} #{document.id} allocation #{allocation.line_no}"
        )
        settlement_reset = Posting::Clearing.reset!(
          clearing_event: settlement_event, actor: actor, reset_on: reset_on,
          reason: "reopen unapplied cash for #{document.doc_type.downcase} #{document.id}"
        )
        allocation.update!(
          target_reset_event_id: target_reset.id,
          settlement_reset_event_id: settlement_reset.id
        )
        allocation
      end
    rescue ActiveRecord::RecordNotFound
      raise InvalidReset, "allocation is unavailable"
    rescue ArgumentError => e
      raise InvalidReset, e.message
    end

    def clearing_event!(document, event_id)
      LedgerEvent.find_by!(tenant_id: document.tenant_id, id: event_id, action: "items.cleared")
    end
  end
end
