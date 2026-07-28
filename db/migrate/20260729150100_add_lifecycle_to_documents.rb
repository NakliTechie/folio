# frozen_string_literal: true

# Batch 4 — document lifecycle (spec §7, §8). draft → parked → posted → reversed, enforced
# on the document. Reversal is a compensating document + event, NEVER a delete: reverses_id /
# reversed_by_id link the two, posted_entry_id points at the Entry the post created.
class AddLifecycleToDocuments < ActiveRecord::Migration[8.1]
  def change
    add_column :documents, :state, :string, null: false, default: "draft" # draft/parked/posted/reversed
    add_column :documents, :narration, :string
    add_column :documents, :posted_entry_id, :bigint                       # the Entry this posted
    add_column :documents, :reverses_document_id, :bigint                  # this reverses that document
    add_column :documents, :reversed_by_document_id, :bigint               # ... reversed by that one
    add_index :documents, [ :tenant_id, :state ]
    add_index :documents, :reverses_document_id

    execute <<~SQL
      ALTER TABLE documents ADD CONSTRAINT chk_documents_state
        CHECK (state IN ('draft','parked','posted','reversed'))
    SQL
  end
end
