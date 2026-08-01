# frozen_string_literal: true

# Corrects the first TDS implementation from payment-time/gross-value withholding to the
# statutory "credit or payment, whichever is earlier" lifecycle. Purchase bills now freeze
# their complete assessment basis, including zero-withholding threshold assessments, so later
# bills can calculate cumulative thresholds without consulting mutable master data.
class CorrectTdsCreditLifecycle < ActiveRecord::Migration[8.1]
  def up
    change_table :documents, bulk: true do |t|
      t.string  :tds_section
      t.string  :tds_statutory_reference
      t.string  :tds_base_basis
      t.string  :tds_trigger_event
      t.integer :tds_rate_basis_points, null: false, default: 0
      t.bigint  :tds_taxable_minor, null: false, default: 0
      t.bigint  :tds_prior_taxable_minor, null: false, default: 0
      t.bigint  :tds_prior_deducted_base_minor, null: false, default: 0
      t.bigint  :tds_deductible_base_minor, null: false, default: 0
      t.bigint  :tds_minor, null: false, default: 0
    end

    add_index :documents,
      [ :tenant_id, :party_id, :fiscal_year, :tds_section ],
      name: "index_documents_on_tds_assessment_scope",
      where: "tds_section IS NOT NULL"

    execute <<~SQL
      ALTER TABLE documents
        ADD CONSTRAINT chk_documents_tds_amounts_nonneg CHECK (
          tds_rate_basis_points >= 0 AND
          tds_taxable_minor >= 0 AND
          tds_prior_taxable_minor >= 0 AND
          tds_prior_deducted_base_minor >= 0 AND
          tds_deductible_base_minor >= 0 AND
          tds_minor >= 0
        ),
        ADD CONSTRAINT chk_documents_tds_snapshot_complete CHECK (
          (tds_section IS NULL AND
           tds_statutory_reference IS NULL AND
           tds_base_basis IS NULL AND
           tds_trigger_event IS NULL AND
           tds_rate_basis_points = 0 AND
           tds_taxable_minor = 0 AND
           tds_prior_taxable_minor = 0 AND
           tds_prior_deducted_base_minor = 0 AND
           tds_deductible_base_minor = 0 AND
           tds_minor = 0)
          OR
          (tds_section IS NOT NULL AND
           tds_statutory_reference IS NOT NULL AND
           tds_base_basis IS NOT NULL AND
           tds_trigger_event IS NOT NULL AND
           tds_taxable_minor > 0 AND
           tds_minor <= tds_deductible_base_minor)
        );
    SQL

    change_table :tds_deductions, bulk: true do |t|
      t.bigint :gross_minor
      t.bigint :gst_minor
      t.bigint :deductible_base_minor
      t.string :base_basis
      t.string :trigger_event
      t.string :statutory_reference
      t.string :kind, null: false, default: "deduction"
      t.bigint :reverses_tds_deduction_id
    end

    # Preserve legacy evidence honestly. These rows were produced at payment time on gross
    # value; they must not be relabelled as invoice/GST-exclusive deductions during migration.
    execute <<~SQL
      UPDATE tds_deductions
      SET gross_minor = taxable_minor,
          gst_minor = 0,
          deductible_base_minor = taxable_minor,
          base_basis = 'legacy_payment_gross',
          trigger_event = 'payment',
          statutory_reference = CASE
            WHEN deduction_date >= DATE '2026-04-01' THEN
              CASE section
                WHEN '194A' THEN 'Income-tax Act 2025 §393(1), Table Sl. 5(ii)/(iii)'
                WHEN '194H' THEN 'Income-tax Act 2025 §393(1), Table Sl. 1(ii)'
                WHEN '194I-a' THEN 'Income-tax Act 2025 §393(1), Table Sl. 2(ii)'
                WHEN '194I-b' THEN 'Income-tax Act 2025 §393(1), Table Sl. 2(ii)'
                WHEN '194C' THEN 'Income-tax Act 2025 §393(1), Table Sl. 6(i)'
                WHEN '194J' THEN 'Income-tax Act 2025 §393(1), Table Sl. 6(iii)'
                WHEN '194Q' THEN 'Income-tax Act 2025 §393(1), Table Sl. 8(ii)'
              END
            ELSE 'Income-tax Act 1961 §' || section
          END;
    SQL

    change_column_null :tds_deductions, :gross_minor, false
    change_column_null :tds_deductions, :gst_minor, false
    change_column_null :tds_deductions, :deductible_base_minor, false
    change_column_null :tds_deductions, :base_basis, false
    change_column_null :tds_deductions, :trigger_event, false
    change_column_null :tds_deductions, :statutory_reference, false

    add_index :tds_deductions, :reverses_tds_deduction_id
    add_index :tds_deductions, [ :tenant_id, :source_document_id ], unique: true
    execute <<~SQL
      ALTER TABLE tds_deductions
        ADD CONSTRAINT tds_deductions_kind_valid
          CHECK (kind IN ('deduction', 'reversal')),
        ADD CONSTRAINT tds_deductions_evidence_amounts_valid
          CHECK (gross_minor >= 0 AND gst_minor >= 0 AND deductible_base_minor >= 0),
        ADD CONSTRAINT tds_deductions_reversal_link_valid CHECK (
          (kind = 'deduction' AND reverses_tds_deduction_id IS NULL) OR
          (kind = 'reversal' AND reverses_tds_deduction_id IS NOT NULL)
        );
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE tds_deductions
        DROP CONSTRAINT IF EXISTS tds_deductions_kind_valid,
        DROP CONSTRAINT IF EXISTS tds_deductions_evidence_amounts_valid,
        DROP CONSTRAINT IF EXISTS tds_deductions_reversal_link_valid;
    SQL
    remove_index :tds_deductions, [ :tenant_id, :source_document_id ]
    remove_index :tds_deductions, :reverses_tds_deduction_id
    change_table :tds_deductions, bulk: true do |t|
      t.remove :gross_minor, :gst_minor, :deductible_base_minor, :base_basis,
        :trigger_event, :statutory_reference, :kind, :reverses_tds_deduction_id
    end

    execute <<~SQL
      ALTER TABLE documents
        DROP CONSTRAINT IF EXISTS chk_documents_tds_amounts_nonneg,
        DROP CONSTRAINT IF EXISTS chk_documents_tds_snapshot_complete;
    SQL
    remove_index :documents, name: "index_documents_on_tds_assessment_scope"
    change_table :documents, bulk: true do |t|
      t.remove :tds_section, :tds_statutory_reference, :tds_base_basis, :tds_trigger_event,
        :tds_rate_basis_points, :tds_taxable_minor, :tds_prior_taxable_minor,
        :tds_prior_deducted_base_minor, :tds_deductible_base_minor, :tds_minor
    end
  end
end
