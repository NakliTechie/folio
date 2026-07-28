# frozen_string_literal: true

# Batch 4 — the document-type registry (spec §8). A document type declares HOW it posts
# (its posting_rule) — the posting core must never know what an invoice is. Versioned config
# is the full shape (D11); v1 keeps a `version` integer the event can cite. Seeds `JV`
# (journal voucher), the simplest type, which exercises the whole loop with no tax.
class CreateDocumentTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :document_types do |t|
      t.bigint  :tenant_id,     null: false
      t.string  :code,          null: false            # JV, SI (sales invoice), ...
      t.string  :label,         null: false
      t.string  :posting_rule,  null: false            # identifies the Posting::Rules::* rule
      t.string  :number_prefix                          # statutory series prefix
      t.integer :version,       null: false, default: 1 # config version cited by the event
      t.boolean :active,        null: false, default: true
      t.timestamps
    end
    add_index :document_types, [ :tenant_id, :code ], unique: true
  end
end
