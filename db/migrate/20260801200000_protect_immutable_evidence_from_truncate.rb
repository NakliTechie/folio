# frozen_string_literal: true

class ProtectImmutableEvidenceFromTruncate < ActiveRecord::Migration[8.1]
  TABLES = %w[
    contract_allocation_runs contract_allocation_lines
    inventory_transactions inventory_movements asset_transactions
    allocation_runs allocation_run_items goods_receipts goods_receipt_lines
    intercompany_transactions consolidation_elimination_runs
    access_review_runs access_review_attestations
    external_signing_keys khata_import_runs
  ].freeze

  def up
    execute <<~SQL
      CREATE FUNCTION folio_immutable_evidence_no_truncate() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '% is immutable: TRUNCATE rejected', TG_TABLE_NAME;
      END;
      $$;
    SQL
    TABLES.each do |table|
      execute <<~SQL
        CREATE TRIGGER #{table}_no_truncate
          BEFORE TRUNCATE ON #{table}
          FOR EACH STATEMENT EXECUTE FUNCTION folio_immutable_evidence_no_truncate();
      SQL
    end
  end

  def down
    TABLES.each do |table|
      execute "DROP TRIGGER IF EXISTS #{table}_no_truncate ON #{table}"
    end
    execute "DROP FUNCTION IF EXISTS folio_immutable_evidence_no_truncate()"
  end
end
