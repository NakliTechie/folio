# frozen_string_literal: true

class BuildPurchaseCreditNotes < ActiveRecord::Migration[8.1]
  def up
    add_index :documents, [ :tenant_id, :party_id, :external_reference ],
      unique: true,
      where: "doc_type = 'PC' AND external_reference IS NOT NULL",
      name: "idx_documents_unique_vendor_credit_reference"

    execute <<~SQL
      INSERT INTO document_types
        (tenant_id, code, label, posting_rule, number_prefix, version, active, created_at, updated_at)
      SELECT tenants.id, 'PC', 'Supplier Credit Note', 'purchase_credit_note', 'PC/', 1, TRUE,
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM tenants
      WHERE NOT EXISTS (
        SELECT 1 FROM document_types
        WHERE document_types.tenant_id = tenants.id AND document_types.code = 'PC'
      )
    SQL
  end

  def down
    execute "DELETE FROM document_types WHERE code = 'PC' AND posting_rule = 'purchase_credit_note'"
    remove_index :documents, name: "idx_documents_unique_vendor_credit_reference"
  end
end
