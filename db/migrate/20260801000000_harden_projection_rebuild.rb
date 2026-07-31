# frozen_string_literal: true

# A ledger event and a posted document each project to at most one Entry per tenant.
# These partial unique indexes are the database backstop for online rebuild exclusion:
# even if a future writer forgets the shared advisory lock, it cannot silently duplicate
# accounting substance for one authoritative event or document.
class HardenProjectionRebuild < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :entries, [ :tenant_id, :ledger_event_id ], unique: true,
      where: "ledger_event_id IS NOT NULL",
      name: "index_entries_on_tenant_event_unique", algorithm: :concurrently
    add_index :entries, [ :tenant_id, :document_id ], unique: true,
      where: "document_id IS NOT NULL",
      name: "index_entries_on_tenant_document_unique", algorithm: :concurrently
  end
end
