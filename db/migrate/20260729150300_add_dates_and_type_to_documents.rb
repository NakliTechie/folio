# frozen_string_literal: true

# Batch 4 — a document carries its business dates and its type. document_type_id links to the
# registry that declares the posting rule; document_date / posting_date flow to the Entry on post.
class AddDatesAndTypeToDocuments < ActiveRecord::Migration[8.1]
  def change
    add_column :documents, :document_type_id, :bigint
    add_column :documents, :document_date, :date
    add_column :documents, :posting_date, :date
    add_index :documents, :document_type_id
  end
end
