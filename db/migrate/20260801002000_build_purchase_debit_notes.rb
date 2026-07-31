# frozen_string_literal: true

class BuildPurchaseDebitNotes < ActiveRecord::Migration[8.1]
  DEBIT_REASONS = %w[price_increase additional_charge underbilling other].freeze
  CREDIT_REASONS = %w[value_reduction service_deficiency return other].freeze

  def up
    add_column :documents, :debit_note_for_document_id, :bigint
    add_index :documents, [ :tenant_id, :debit_note_for_document_id, :state ],
      name: "idx_documents_debit_note_source"
    add_column :document_lines, :debited_document_line_id, :bigint
    add_index :document_lines, :debited_document_line_id
    add_index :documents, [ :tenant_id, :party_id, :external_reference ],
      unique: true,
      where: "doc_type = 'PD' AND external_reference IS NOT NULL",
      name: "idx_documents_unique_vendor_debit_reference"

    remove_check_constraint :documents, name: "chk_documents_credit_note_reason"
    add_check_constraint :documents,
      "reason_code IS NULL OR reason_code IN (#{all_reasons.map { |reason| connection.quote(reason) }.join(', ')})",
      name: "chk_documents_adjustment_reason"

    execute <<~SQL
      INSERT INTO document_types
        (tenant_id, code, label, posting_rule, number_prefix, version, active, created_at, updated_at)
      SELECT tenants.id, 'PD', 'Supplier Debit Note', 'purchase_debit_note', 'PD/', 1, TRUE,
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM tenants
      WHERE NOT EXISTS (
        SELECT 1 FROM document_types
        WHERE document_types.tenant_id = tenants.id AND document_types.code = 'PD'
      )
    SQL
  end

  def down
    execute "DELETE FROM document_types WHERE code = 'PD' AND posting_rule = 'purchase_debit_note'"
    remove_check_constraint :documents, name: "chk_documents_adjustment_reason"
    add_check_constraint :documents,
      "reason_code IS NULL OR reason_code IN (#{CREDIT_REASONS.map { |reason| connection.quote(reason) }.join(', ')})",
      name: "chk_documents_credit_note_reason"
    remove_index :documents, name: "idx_documents_unique_vendor_debit_reference"
    remove_index :document_lines, :debited_document_line_id
    remove_column :document_lines, :debited_document_line_id
    remove_index :documents, name: "idx_documents_debit_note_source"
    remove_column :documents, :debit_note_for_document_id
  end

  private

  def all_reasons = (CREDIT_REASONS + DEBIT_REASONS).uniq
end
