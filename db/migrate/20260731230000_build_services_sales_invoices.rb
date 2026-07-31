# frozen_string_literal: true

# Stage 3B: a services-first GST sales document whose party, registration, classification,
# tax basis, and totals are frozen before posting and reproduced in the fat posting event.
class BuildServicesSalesInvoices < ActiveRecord::Migration[8.1]
  def up
    change_table :documents, bulk: true do |t|
      t.bigint :party_id
      t.bigint :tax_registration_id
      t.string :supply_type
      t.string :place_of_supply_state_code
      t.date :due_date
      t.string :currency, limit: 3
      t.integer :minor_unit_exponent
      t.bigint :subtotal_minor
      t.bigint :tax_minor
      t.bigint :total_minor
      t.jsonb :party_snapshot
      t.jsonb :tax_registration_snapshot
      t.jsonb :tax_breakdown
    end
    add_index :documents, [ :tenant_id, :party_id, :document_date ],
      name: "idx_documents_tenant_party_date"
    add_index :documents, [ :tenant_id, :tax_registration_id, :document_date ],
      name: "idx_documents_tenant_tax_registration_date"
    add_check_constraint :documents,
      "supply_type IS NULL OR supply_type IN ('B2B', 'B2C')", name: "chk_documents_supply_type"
    add_check_constraint :documents,
      "subtotal_minor IS NULL OR (subtotal_minor > 0 AND tax_minor >= 0 AND total_minor = subtotal_minor + tax_minor)",
      name: "chk_documents_invoice_totals"

    change_table :document_lines, bulk: true do |t|
      t.bigint :item_id
      t.decimal :quantity, precision: 20, scale: 6
      t.bigint :unit_price_minor
      t.bigint :taxable_minor
      t.string :hsn_sac_code
      t.integer :tax_rate_basis_points
      t.integer :cess_rate_basis_points
      t.jsonb :tax_components
      t.jsonb :item_snapshot
    end
    add_index :document_lines, :item_id
    add_check_constraint :document_lines,
      "item_id IS NULL OR (quantity > 0 AND unit_price_minor >= 0 AND taxable_minor > 0)",
      name: "chk_document_lines_invoice_amounts"
    add_check_constraint :document_lines,
      "tax_rate_basis_points IS NULL OR tax_rate_basis_points BETWEEN 0 AND 4000",
      name: "chk_document_lines_tax_rate"
    add_check_constraint :document_lines,
      "cess_rate_basis_points IS NULL OR cess_rate_basis_points BETWEEN 0 AND 10000",
      name: "chk_document_lines_cess_rate"

    change_table :entry_lines, bulk: true do |t|
      t.string :hsn_sac_code
      t.string :tax_component
      t.integer :tax_rate_basis_points
      t.bigint :taxable_amount_minor
    end
    add_index :entry_lines,
      [ :tenant_id, :tax_registration_id, :tax_component ],
      name: "idx_entry_lines_tax_reporting",
      where: "tax_component IS NOT NULL"
    add_check_constraint :entry_lines,
      "tax_component IS NULL OR tax_component IN ('cgst', 'sgst', 'utgst', 'igst', 'cess')",
      name: "chk_entry_lines_tax_component"

    execute <<~SQL
      INSERT INTO document_types
        (tenant_id, code, label, posting_rule, number_prefix, version, active, created_at, updated_at)
      SELECT tenants.id, 'SI', 'Sales Invoice', 'sales_invoice', 'SI/', 1, TRUE,
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM tenants
      WHERE NOT EXISTS (
        SELECT 1 FROM document_types
        WHERE document_types.tenant_id = tenants.id AND document_types.code = 'SI'
      )
    SQL
  end

  def down
    execute "DELETE FROM document_types WHERE code = 'SI' AND posting_rule = 'sales_invoice'"
    remove_check_constraint :entry_lines, name: "chk_entry_lines_tax_component"
    remove_index :entry_lines, name: "idx_entry_lines_tax_reporting"
    remove_columns :entry_lines, :hsn_sac_code, :tax_component,
      :tax_rate_basis_points, :taxable_amount_minor
    remove_check_constraint :document_lines, name: "chk_document_lines_cess_rate"
    remove_check_constraint :document_lines, name: "chk_document_lines_tax_rate"
    remove_check_constraint :document_lines, name: "chk_document_lines_invoice_amounts"
    remove_index :document_lines, :item_id
    remove_columns :document_lines, :item_id, :quantity, :unit_price_minor, :taxable_minor,
      :hsn_sac_code, :tax_rate_basis_points, :cess_rate_basis_points, :tax_components, :item_snapshot
    remove_check_constraint :documents, name: "chk_documents_invoice_totals"
    remove_check_constraint :documents, name: "chk_documents_supply_type"
    remove_index :documents, name: "idx_documents_tenant_tax_registration_date"
    remove_index :documents, name: "idx_documents_tenant_party_date"
    remove_columns :documents, :party_id, :tax_registration_id, :supply_type,
      :place_of_supply_state_code, :due_date, :currency, :minor_unit_exponent,
      :subtotal_minor, :tax_minor, :total_minor, :party_snapshot,
      :tax_registration_snapshot, :tax_breakdown
  end
end
