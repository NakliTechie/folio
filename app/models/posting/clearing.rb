# frozen_string_literal: true

require "json"

# Open-item clearing (spec §5, decision D5) — the field that replaces SAP's entire Special
# G/L machinery. Clearing is an EVENT (never an UPDATE to the log); the projection change
# is applied by replay!, so clear! = append + replay, exactly like PostEntry.
#
# The two clearing modes are permanent and semantically distinct:
#   partial  — the original item stays open, ageing PRESERVED (baseline_date unchanged);
#              cleared_amount_minor accumulates, outstanding shrinks.
#   residual — the original item is cleared, a NEW open item opens for the balance with a
#              FRESH baseline_date, ageing RESET.
# Getting this wrong produces wrong aged payables, a top-three report.
#
# Replayability: the cleared item is targeted by its stable (source_event_id, ledger_id,
# line_no) key — the ledger_event that created the line, never a projection id — and the clearing entry is
# referenced by its ledger_event_id. Both are stable because ledger_events is never rebuilt
# (only the projection is), so a full Posting.rebuild! reproduces the cleared state
# deterministically, and a residual (or a reused assignment) can never be mis-targeted.
module Posting
  class Clearing
    MODES = %w[full partial residual].freeze

    # Outstanding on an open item = |transaction-slot amount| − already-cleared.
    def self.open_amount(line)
      txn = line.amounts.find_by(slot_role: "transaction")
      (txn ? txn.amount_minor.abs : 0) - line.cleared_amount_minor
    end

    # Days outstanding as of a date, from the (re-baselineable) baseline_date.
    def self.age_days(line, as_of:)
      return nil unless line.baseline_date
      (as_of.to_date - line.baseline_date).to_i
    end

    # Clear (part of) an open item. `mode` is honoured only for a part-payment; a full-
    # amount application is always "full". Appends an items.cleared event and projects it.
    # The item may be an original OR a residual — it is targeted by its stable
    # (source_event_id, ledger_id, line_no) key, so re-clearing a residual works and an assignment
    # reused across invoices can never mis-target.
    def self.clear!(item:, amount_minor:, cleared_on:, mode:, clearing_entry: nil,
                    actor: "system", reason: nil)
      raise ArgumentError, "mode must be one of #{MODES}" unless MODES.include?(mode.to_s)
      raise ArgumentError, "item is not open" unless item.open_item? && item.cleared_on.nil?
      raise ArgumentError, "the item has no stable source_event_id to target" if item.source_event_id.blank?

      outstanding = open_amount(item)
      amt = Integer(amount_minor)
      raise ArgumentError, "amount #{amt} must be positive" unless amt.positive?
      raise ArgumentError, "amount #{amt} exceeds outstanding #{outstanding}" if amt > outstanding
      if mode.to_s == "full" && amt < outstanding
        raise ArgumentError, "full clearing amount #{amt} must equal outstanding #{outstanding}"
      end

      resolved = amt == outstanding ? "full" : mode.to_s

      payload = PostEntry.deep_compact(
        "clearing" => {
          # Stable target: the exact line, by its creating event + ledger + line number.
          # `ledgerId` is additive; replay_target retains the pre-v2 two-field fallback.
          "target" => stable_target(item),
          "assignment" => item.assignment, "accountCode" => item.account_code,
          "amountMinor" => amt, "mode" => resolved, "clearedOn" => cleared_on.to_s,
          "clearingEventId" => clearing_entry&.ledger_event_id, "reason" => reason,
          "residualBaselineDate" => ("residual" == resolved ? cleared_on.to_s : nil)
        }
      )

      ActiveRecord::Base.transaction do
        event = LedgerEvent.append!(
          tenant_id: item.tenant_id, actor: actor, action: "items.cleared",
          origin: "folio", ts: cleared_on.to_s,
          payload_str: Folio::KhataHash.canonical_payload(payload)
        )
        replay!(event)
        event
      end
    end

    # Project an items.cleared event onto the read model. Targets the EXACT open item by its
    # stable (source_event_id, ledger_id, line_no) key. Pure w.r.t. the payload except for resolving the
    # clearing entry's CURRENT id from its stable ledger_event_id.
    def self.replay!(event)
      data = JSON.parse(event.payload)
      c = data["clearing"]
      return nil unless c.is_a?(Hash) && c["target"].is_a?(Hash)

      item = replay_target(event.tenant_id, c.fetch("target"))
      # Defensive: only an OPEN item can be cleared; a stale/duplicate event is a no-op.
      return nil unless item&.open_item? && item.cleared_on.nil?

      amt = Integer(c["amountMinor"])
      clearing_entry_id =
        if c["clearingEventId"]
          Entry.find_by(tenant_id: event.tenant_id, ledger_event_id: c["clearingEventId"])&.id
        end

      case c["mode"]
      when "partial"
        # stays open; ageing preserved (baseline_date untouched).
        item.update!(cleared_amount_minor: item.cleared_amount_minor + amt, clearing_reason: c["reason"])
      when "full"
        item.update!(cleared_amount_minor: item.cleared_amount_minor + amt,
                     cleared_by_entry_id: clearing_entry_id, cleared_on: c["clearedOn"],
                     clearing_reason: c["reason"])
      when "residual"
        remaining = open_amount(item) - amt # outstanding-before − applied
        txn = item.amounts.find_by(slot_role: "transaction")
        sign = txn && txn.amount_minor.negative? ? -1 : 1
        item.update!(cleared_amount_minor: item.cleared_amount_minor + amt,
                     cleared_by_entry_id: clearing_entry_id, cleared_on: c["clearedOn"],
                     clearing_reason: c["reason"])
        open_residual!(item: item, remaining: remaining, sign: sign, txn: txn,
                       baseline: c["residualBaselineDate"], source_event_id: event.id,
                       host_entry_id: clearing_entry_id || item.entry_id)
      end
      item
    end

    def self.reset!(clearing_event:, actor:, reset_on:, reason: nil)
      ActiveRecord::Base.transaction do
        # Rebuild deletes the line projection, so take the tenant event lock before
        # locking that line. Callers may already hold it; transaction advisory locks
        # are safely re-entrant on the same connection.
        LedgerEvent.acquire_tenant_lock!(clearing_event.tenant_id)
        raise ArgumentError, "only a clearing event can be reset" unless clearing_event.action == "items.cleared"
        raise ArgumentError, "clearing was already reset" if reset_event_for(clearing_event)

        clearing = JSON.parse(clearing_event.payload).fetch("clearing")
        item = replay_target(clearing_event.tenant_id, clearing.fetch("target"), lock: true)
        raise ActiveRecord::RecordNotFound, "clearing target is unavailable" unless item
        validate_resettable!(item, clearing_event, clearing)
        payload = {
          "clearingReset" => {
            "clearingEventId" => clearing_event.id,
            "target" => clearing.fetch("target"),
            "amountMinor" => clearing.fetch("amountMinor"),
            "mode" => clearing.fetch("mode"),
            "reason" => reason
          }.compact
        }
        event = LedgerEvent.append!(
          tenant_id: clearing_event.tenant_id, actor: actor,
          action: "items.clearing_reset", origin: "folio", ts: reset_on.to_s,
          payload_str: Folio::KhataHash.canonical_payload(payload)
        )
        replay_reset!(event)
        event
      end
    end

    def self.replay_reset!(event)
      reset = JSON.parse(event.payload)["clearingReset"]
      return unless reset

      original = LedgerEvent.find_by(
        tenant_id: event.tenant_id, id: reset["clearingEventId"], action: "items.cleared"
      )
      return unless original

      clearing = JSON.parse(original.payload).fetch("clearing")
      item = replay_target(event.tenant_id, clearing.fetch("target"))
      return unless item

      amount = Integer(clearing.fetch("amountMinor"))
      if clearing.fetch("mode") == "residual"
        residual = item.residuals.find_by(source_event_id: original.id)
        residual&.destroy!
      end
      item.update!(
        cleared_amount_minor: item.cleared_amount_minor - amount,
        cleared_by_entry_id: nil,
        cleared_on: nil,
        clearing_reason: nil
      )
      item
    end

    def self.reset_event_for(clearing_event)
      LedgerEvent.where(tenant_id: clearing_event.tenant_id, action: "items.clearing_reset").find do |event|
        JSON.parse(event.payload).dig("clearingReset", "clearingEventId").to_i == clearing_event.id
      end
    end

    def self.stable_target(item)
      {
        "sourceEventId" => item.source_event_id,
        "ledgerId" => item.ledger_id,
        "lineNo" => item.line_no
      }
    end

    # Events written before ledgerId was added retain their two-field lookup. That is
    # deterministic for the v1 single-ledger corpus; all new events name the ledger so an
    # extension-ledger line with the same event/line number cannot be selected instead.
    def self.replay_target(tenant_id, target, lock: false)
      scope = EntryLine.where(
        tenant_id: tenant_id,
        source_event_id: target["sourceEventId"],
        line_no: target["lineNo"]
      )
      scope = scope.where(ledger_id: target["ledgerId"]) if target.key?("ledgerId")
      scope = scope.lock if lock
      scope.order(:id).first
    end

    def self.validate_resettable!(item, clearing_event, clearing)
      amount = Integer(clearing.fetch("amountMinor"))
      raise ArgumentError, "clearing projection no longer contains the applied amount" if item.cleared_amount_minor < amount

      case clearing.fetch("mode")
      when "partial"
        raise ArgumentError, "a later full clearing must be reset first" if item.cleared_on.present?
      when "full"
        raise ArgumentError, "the item is not fully cleared" if item.cleared_on.nil?
      when "residual"
        residual = item.residuals.find_by(source_event_id: clearing_event.id)
        unless residual&.open_item? && residual.cleared_on.nil? && residual.cleared_amount_minor.zero? &&
               residual.residuals.empty?
          raise ArgumentError, "the residual has later activity and cannot be reset"
        end
      end
    end

    # The new statistical open item that a residual clearing opens, with a fresh baseline
    # (ageing reset). Its amount drives subledger clearing only; the source document and
    # settlement already contain the complete general-ledger accounting.
    # source_event_id = the clearing event, so the residual has its own stable (event, ledger, line_no)
    # key and can itself be cleared later.
    def self.open_residual!(item:, remaining:, sign:, txn:, baseline:, source_event_id:, host_entry_id:)
      next_no = EntryLine.where(entry_id: host_entry_id, ledger_id: item.ledger_id).maximum(:line_no).to_i + 1
      residual = EntryLine.create!(
        tenant_id: item.tenant_id, entry_id: host_entry_id, ledger_id: item.ledger_id,
        entity_id: item.entity_id, office_id: item.office_id, account_code: item.account_code,
        line_no: next_no, source_event_id: source_event_id, party_id: item.party_id,
        party_role: item.party_role, open_item: true, item_class: item.item_class,
        assignment: item.assignment, baseline_date: baseline, residual_of_line_id: item.id,
        line_class: "statistical", posting_layer: "00"
      )
      return residual unless txn

      JournalEntryLineAmount.create!(
        tenant_id: item.tenant_id, entry_line_id: residual.id, slot_role: "transaction",
        currency: txn.currency, minor_unit_exponent: txn.minor_unit_exponent, amount_minor: sign * remaining
      )
      residual
    end
  end
end
