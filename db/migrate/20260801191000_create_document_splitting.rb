# frozen_string_literal: true

# Batch 9: zero-balance document splitting. A technical clearing account nets to zero
# for the whole company while making each profit-center/segment slice self-balancing.
class CreateDocumentSplitting < ActiveRecord::Migration[8.1]
  def up
    now = connection.quote(Time.current)
    execute <<~SQL.squish
      INSERT INTO accounts (tenant_id, code, name, account_type, active, monetary, created_at, updated_at)
      SELECT tenants.id, '2990', 'Document Splitting Clearing', 'liability', TRUE, FALSE,
        #{now}, #{now}
      FROM tenants
      WHERE NOT EXISTS (
        SELECT 1 FROM accounts WHERE accounts.tenant_id = tenants.id AND accounts.code = '2990'
      )
    SQL
  end

  def down
    # Account master codes are intentionally durable: a migration rollback must not delete
    # a code that a historical journal event may already reference.
  end
end
