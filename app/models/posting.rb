# frozen_string_literal: true

# The posting namespace. Defining it explicitly (rather than as a Zeitwerk implicit
# namespace) keeps nested constants — PostEntry, Clearing, UnbalancedError — resolvable
# regardless of load order.
#
# project!/rebuild! are the projection side of the event-sourced ledger: ledger_events is
# the append-only source of truth; the entries/entry_lines/amounts projection is derived
# and can be wiped and rebuilt from the log at any time. That is what makes replay the
# integrity guarantee it is.
module Posting
  IntegrityError = Class.new(StandardError)

  module_function

  # Project ONE event into the read model, dispatched by action. Bahi's thin corpus events
  # (e.g. "entry.post") have no Folio projection and are skipped; only Folio's own fat
  # events project.
  def project!(event)
    case event.action
    when "entry.posted"  then PostEntry.replay!(event)
    when "items.cleared"        then Clearing.replay!(event)
    when "items.clearing_reset" then Clearing.replay_reset!(event)
    end
  end

  # Wipe a tenant's projection and rebuild it from the log, in seq order. Because clearing
  # events reference earlier entries, order matters — in_order (by seq) guarantees an entry
  # is projected before any clearing that touches it. The tenant event lock excludes writers
  # for the whole wipe/replay/rebind window; document pointers are mutable workflow projection
  # state and are rebound only after every event has replayed successfully.
  def rebuild!(tenant_id)
    ActiveRecord::Base.transaction do
      LedgerEvent.acquire_tenant_lock!(tenant_id)
      verification = LedgerEvent.verify_chain(tenant_id)
      unless verification.fetch(:ok)
        raise IntegrityError,
          "event chain is invalid at sequence #{verification[:broken_at]} (#{verification[:reason]})"
      end
      Document.where(tenant_id: tenant_id).update_all(posted_entry_id: nil)
      Entry.where(tenant_id: tenant_id).destroy_all
      import_run = KhataImportRun.find_by(tenant_id: tenant_id)
      if import_run
        Khata::RecoveryProjection.restore!(import_run)
        events = LedgerEvent.for_tenant(tenant_id).where("seq > ?", import_run.source_audit_rows)
        events.in_order.each { |event| project!(event) }
      else
        LedgerEvent.for_tenant(tenant_id).in_order.each { |event| project!(event) }
      end
      rebind_document_entries!(tenant_id)
    end
  end

  def rebind_document_entries!(tenant_id)
    Entry.where(tenant_id: tenant_id).where.not(document_id: nil).find_each do |entry|
      Document.where(tenant_id: tenant_id, id: entry.document_id)
        .update_all(posted_entry_id: entry.id)
    end
  end
end
