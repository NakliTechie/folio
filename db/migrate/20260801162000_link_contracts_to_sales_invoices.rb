# frozen_string_literal: true

# A contract-linked sales invoice bills against deferred revenue. Recognition remains a
# separate schedule-driven posting, so billing and performance can lead or lag one another.
class LinkContractsToSalesInvoices < ActiveRecord::Migration[8.1]
  def up
    add_reference :documents, :contract, foreign_key: true
    add_column :documents, :contract_snapshot, :jsonb
    add_index :documents, %i[tenant_id contract_id posting_date state],
      name: "index_documents_on_contract_posting"

    now = connection.quote(Time.current)
    execute <<~SQL.squish
      INSERT INTO accounts (tenant_id, code, name, account_type, active, created_at, updated_at)
      SELECT tenants.id, seeded.code, seeded.name, seeded.account_type, TRUE, #{now}, #{now}
      FROM tenants
      CROSS JOIN (VALUES
        ('1190', 'Contract Assets (Unbilled Revenue)', 'asset'),
        ('2200', 'Contract Liabilities (Deferred Revenue)', 'liability')
      ) AS seeded(code, name, account_type)
      WHERE NOT EXISTS (
        SELECT 1 FROM accounts
        WHERE accounts.tenant_id = tenants.id AND accounts.code = seeded.code
      )
    SQL
  end

  def down
    remove_index :documents, name: "index_documents_on_contract_posting"
    remove_column :documents, :contract_snapshot
    remove_reference :documents, :contract, foreign_key: true
  end
end
