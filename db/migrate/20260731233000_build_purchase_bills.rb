# frozen_string_literal: true

class BuildPurchaseBills < ActiveRecord::Migration[8.1]
  def up
    add_index :documents, [ :tenant_id, :party_id, :external_reference ],
      unique: true,
      where: "doc_type = 'PB' AND external_reference IS NOT NULL",
      name: "idx_documents_unique_vendor_bill_reference"

    execute <<~SQL
      INSERT INTO accounts
        (tenant_id, code, name, account_type, active, created_at, updated_at)
      SELECT tenants.id, '1210', 'GST Input Credit', 'asset', TRUE,
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM tenants
      WHERE NOT EXISTS (
        SELECT 1 FROM accounts
        WHERE accounts.tenant_id = tenants.id AND accounts.code = '1210'
      )
    SQL

    execute <<~SQL
      INSERT INTO financial_statement_assignments
        (tenant_id, financial_statement_version_id, financial_statement_section_id,
         account_id, created_at, updated_at)
      SELECT accounts.tenant_id, versions.id, sections.id, accounts.id,
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM accounts
      JOIN financial_statement_versions versions
        ON versions.tenant_id = accounts.tenant_id
      JOIN financial_statement_sections sections
        ON sections.tenant_id = accounts.tenant_id
       AND sections.financial_statement_version_id = versions.id
       AND sections.code = 'current_assets'
      WHERE accounts.code = '1210'
        AND NOT EXISTS (
          SELECT 1 FROM financial_statement_assignments assignments
          WHERE assignments.tenant_id = accounts.tenant_id
            AND assignments.financial_statement_version_id = versions.id
            AND assignments.account_id = accounts.id
        )
    SQL

    execute <<~SQL
      INSERT INTO document_types
        (tenant_id, code, label, posting_rule, number_prefix, version, active, created_at, updated_at)
      SELECT tenants.id, 'PB', 'Purchase Bill', 'purchase_bill', 'PB/', 1, TRUE,
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM tenants
      WHERE NOT EXISTS (
        SELECT 1 FROM document_types
        WHERE document_types.tenant_id = tenants.id AND document_types.code = 'PB'
      )
    SQL

    execute <<~SQL
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, 'bills.create', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      WHERE role_templates.code IN ('accountant', 'operator')
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = 'bills.create'
        )
    SQL
  end

  def down
    execute "DELETE FROM role_permissions WHERE capability = 'bills.create'"
    execute "DELETE FROM document_types WHERE code = 'PB' AND posting_rule = 'purchase_bill'"
    remove_index :documents, name: "idx_documents_unique_vendor_bill_reference"
  end
end
