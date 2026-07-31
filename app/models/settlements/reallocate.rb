# frozen_string_literal: true

module Settlements
  module Reallocate
    module_function

    def call(document:, allocation_id:, target_entry_line_id:, clearing_mode:, actor:, applied_on: Date.current)
      ActiveRecord::Base.transaction do
        LedgerEvent.acquire_tenant_lock!(document.tenant_id)
        document.lock!
        allocation = document.document_allocations.lock.find(allocation_id)
        unless document.state == "posted" && allocation.reset? && allocation.settlement_reallocation.nil?
          raise InvalidReset, "allocation must be reset before it can be reapplied"
        end
        raise InvalidReset, "reallocation date cannot precede the settlement" if applied_on < document.document_date

        config = Settlements::BuildDraft::TYPES.fetch(document.doc_type)
        target = EntryLine.where(tenant_id: document.tenant_id).find(target_entry_line_id)
        settlement_line = settlement_line_for(document, allocation)
        EntryLine.where(id: [ target.id, settlement_line.id ]).order(:id).lock.load
        target.reload
        settlement_line.reload
        validate_pair!(document, allocation, target, settlement_line, config, clearing_mode)

        reallocation = SettlementReallocation.create!(
          tenant_id: document.tenant_id, document_allocation: allocation,
          target_entry_line_id: target.id, target_source_event_id: target.source_event_id,
          target_line_no: target.line_no, amount_minor: allocation.amount_minor,
          clearing_mode: clearing_mode, target_snapshot: Settlements::BuildDraft.target_snapshot(target)
        )
        entry = settlement_line.entry
        outstanding = Posting::Clearing.open_amount(target)
        mode = allocation.amount_minor == outstanding ? :full : clearing_mode.to_sym
        target_event = Posting::Clearing.clear!(
          item: target, amount_minor: allocation.amount_minor, cleared_on: applied_on,
          mode: mode, clearing_entry: entry, actor: actor,
          reason: "reapplied #{document.doc_type.downcase} #{document.id} allocation #{allocation.line_no}"
        )
        settlement_event = Posting::Clearing.clear!(
          item: settlement_line, amount_minor: allocation.amount_minor, cleared_on: applied_on,
          mode: :full, clearing_entry: entry, actor: actor,
          reason: "reapplied to #{target.assignment}"
        )
        reallocation.update!(
          target_clearing_event_id: target_event.id,
          settlement_clearing_event_id: settlement_event.id
        )
        reallocation
      end
    rescue ActiveRecord::RecordNotFound
      raise InvalidReset, "allocation or target is unavailable"
    rescue ArgumentError => e
      raise InvalidReset, e.message
    end

    def settlement_line_for(document, allocation)
      EntryLine.joins(:entry).find_by!(
        tenant_id: document.tenant_id,
        entries: { document_id: document.id },
        line_no: allocation.line_no + 1
      )
    end

    def validate_pair!(document, allocation, target, settlement_line, config, clearing_mode)
      unless DocumentAllocation::MODES.include?(clearing_mode.to_s)
        raise InvalidReset, "choose partial or residual clearing"
      end
      unless Settlements::BuildDraft.eligible_target?(target, config) && target.party_id == document.party_id &&
             Posting::Clearing.open_amount(target) >= allocation.amount_minor
        raise InvalidReset, "choose an eligible same-party open item with enough outstanding balance"
      end
      settlement_amount = settlement_line.amounts.find_by(slot_role: "transaction")&.amount_minor.to_i
      expected_direction = document.doc_type == "RC" ? -1 : 1
      unless settlement_line.open_item? && settlement_line.cleared_on.nil? &&
             Posting::Clearing.open_amount(settlement_line) == allocation.amount_minor &&
             settlement_amount * expected_direction > 0
        raise InvalidReset, "the unapplied cash line is unavailable"
      end
    end
  end
end
