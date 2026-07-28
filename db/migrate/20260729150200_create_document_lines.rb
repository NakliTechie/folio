# frozen_string_literal: true

# Batch 4 — document lines, generic over document type. A line is the USER's input (a JV
# line: an account and a signed amount); the type's posting rule turns lines into the entry
# lines the core posts. Signed minor units, consistent with the ledger (positive = debit,
# negative = credit). `extra` carries type-specific fields the core never interprets.
class CreateDocumentLines < ActiveRecord::Migration[8.1]
  def change
    create_table :document_lines do |t|
      t.bigint   :tenant_id,          null: false
      t.bigint   :document_id,        null: false
      t.integer  :line_no,            null: false
      t.string   :account_code,       null: false
      t.bigint   :amount_minor,       null: false            # signed; + = debit, - = credit
      t.string   :currency,           null: false, default: "INR", limit: 3
      t.integer  :minor_unit_exponent, null: false, default: 2
      t.string   :narration
      t.jsonb    :extra                                       # type-specific, core-opaque
      t.timestamps
    end
    add_index :document_lines, :document_id
    add_index :document_lines, [ :document_id, :line_no ], unique: true
  end
end
