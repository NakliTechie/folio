# frozen_string_literal: true

class HardenTdsEvidence < ActiveRecord::Migration[8.1]
  def up
    add_column :tds_deductions, :ledger_event_id, :bigint
    add_index :tds_deductions, [ :tenant_id, :ledger_event_id ], unique: true,
      where: "ledger_event_id IS NOT NULL", name: "idx_tds_deductions_event"
    execute <<~SQL
      UPDATE tds_deductions AS deduction
      SET ledger_event_id = entries.ledger_event_id
      FROM entries
      WHERE entries.id = deduction.entry_id
        AND entries.tenant_id = deduction.tenant_id;

      CREATE FUNCTION folio_tds_evidence_immutable() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'tds_deductions are immutable';
      END;
      $$;
      CREATE TRIGGER tds_deductions_immutable
        BEFORE UPDATE OR DELETE ON tds_deductions
        FOR EACH ROW EXECUTE FUNCTION folio_tds_evidence_immutable();
      CREATE TRIGGER tds_deductions_no_truncate
        BEFORE TRUNCATE ON tds_deductions
        FOR EACH STATEMENT EXECUTE FUNCTION folio_immutable_evidence_no_truncate();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS tds_deductions_no_truncate ON tds_deductions;
      DROP TRIGGER IF EXISTS tds_deductions_immutable ON tds_deductions;
      DROP FUNCTION IF EXISTS folio_tds_evidence_immutable();
    SQL
    remove_index :tds_deductions, name: "idx_tds_deductions_event"
    remove_column :tds_deductions, :ledger_event_id
  end
end
