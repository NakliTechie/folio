# frozen_string_literal: true

# B3.1 — document identity (spec §8, decision D8).
#
# This is the IDENTITY object, not the full document-centric entry system — that is
# Batch 4 (document_types, posting-rule abstraction, document_lines, lifecycle). Here we
# lay only what D8 says cannot be added later: a statutory document number allocated from
# number_ranges (never a Postgres sequence), and an external reference (XBLNR-equivalent)
# with a composite index for duplicate-invoice detection from day one.
#
# doc_type is a plain string in v1; the versioned document_types registry is Batch 4.
# A document may later carry TWO registration-scoped perspectives from one posting event
# (owner answer Q7) — that is a Batch 4 shape concern and not built here.
class CreateDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :documents do |t|
      t.bigint :tenant_id,          null: false
      t.bigint :entity_id,          null: false
      t.bigint :office_id,          null: false
      t.string :doc_type,           null: false                 # versioned registry is Batch 4
      t.integer :fiscal_year,       null: false
      t.string :document_number                                 # allocated from number_ranges at post
      t.string :external_reference                              # XBLNR — duplicate-invoice detection
      t.timestamps
    end

    # Statutory number is unique within its series once allocated.
    add_index :documents, [ :tenant_id, :entity_id, :office_id, :doc_type, :fiscal_year, :document_number ],
      unique: true, name: "index_documents_on_series_and_number",
      where: "document_number IS NOT NULL"
    # Duplicate-invoice detection: the same external ref from the same party/office is a flag.
    add_index :documents, [ :tenant_id, :entity_id, :external_reference ],
      name: "index_documents_on_external_reference",
      where: "external_reference IS NOT NULL"
  end
end
