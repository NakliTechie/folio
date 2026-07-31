# frozen_string_literal: true

class SeedRefundDocumentType < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      INSERT INTO document_types
        (tenant_id, code, label, posting_rule, number_prefix, version, active, created_at, updated_at)
      SELECT id, 'RF', 'Open-item Refund', 'open_item_refund', 'RF/', 1, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM tenants
      ON CONFLICT (tenant_id, code) DO NOTHING
    SQL
  end

  def down
    execute <<~SQL.squish
      DELETE FROM document_types
      WHERE code = 'RF' AND posting_rule = 'open_item_refund'
        AND NOT EXISTS (SELECT 1 FROM documents WHERE documents.document_type_id = document_types.id)
    SQL
  end
end
