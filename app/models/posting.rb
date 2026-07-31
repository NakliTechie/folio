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
  module_function

  # Project ONE event into the read model, dispatched by action. Bahi's thin corpus events
  # (e.g. "entry.post") have no Folio projection and are skipped; only Folio's own fat
  # events project.
  def project!(event)
    case event.action
    when "entry.posted"  then PostEntry.replay!(event)
    when "items.cleared" then Clearing.replay!(event)
    end
  end

  # Wipe a tenant's projection and rebuild it from the log, in seq order. Because clearing
  # events reference earlier entries, order matters — in_order (by seq) guarantees an entry
  # is projected before any clearing that touches it.
  def rebuild!(tenant_id)
    ActiveRecord::Base.transaction do
      Entry.where(tenant_id: tenant_id).destroy_all
      LedgerEvent.for_tenant(tenant_id).in_order.each { |event| project!(event) }
    end
  end
end
