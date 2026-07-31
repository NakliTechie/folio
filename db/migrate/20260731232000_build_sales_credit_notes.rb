# frozen_string_literal: true

class BuildSalesCreditNotes < ActiveRecord::Migration[8.1]
  def up
    change_table :documents, bulk: true do |table|
      table.bigint :credit_note_for_document_id
      table.string :reason_code
    end
    add_index :documents, [ :tenant_id, :credit_note_for_document_id, :state ],
      name: "idx_documents_credit_note_source"
    add_check_constraint :documents,
      "reason_code IS NULL OR reason_code IN ('value_reduction', 'service_deficiency', 'return', 'other')",
      name: "chk_documents_credit_note_reason"

    add_column :document_lines, :credited_document_line_id, :bigint
    add_index :document_lines, :credited_document_line_id

    execute <<~SQL
      INSERT INTO document_types
        (tenant_id, code, label, posting_rule, number_prefix, version, active, created_at, updated_at)
      SELECT tenants.id, 'CN', 'Credit Note', 'credit_note', 'CN/', 1, TRUE,
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM tenants
      WHERE NOT EXISTS (
        SELECT 1 FROM document_types
        WHERE document_types.tenant_id = tenants.id AND document_types.code = 'CN'
      )
    SQL
  end

  def down
    execute "DELETE FROM document_types WHERE code = 'CN' AND posting_rule = 'credit_note'"
    remove_index :document_lines, :credited_document_line_id
    remove_column :document_lines, :credited_document_line_id
    remove_check_constraint :documents, name: "chk_documents_credit_note_reason"
    remove_index :documents, name: "idx_documents_credit_note_source"
    remove_columns :documents, :credit_note_for_document_id, :reason_code
  end
end
