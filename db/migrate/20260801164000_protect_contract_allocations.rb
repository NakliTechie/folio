# frozen_string_literal: true

# Allocation versions are accounting judgements, not mutable projections. Corrections append a
# new version and leave the exact prior basis available for schedule/ledger drill-back.
class ProtectContractAllocations < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE FUNCTION folio_contract_allocations_immutable() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '% is immutable: % on row id=% rejected', TG_TABLE_NAME, TG_OP, OLD.id;
      END;
      $$;

      CREATE TRIGGER contract_allocation_runs_immutable
        BEFORE UPDATE OR DELETE ON contract_allocation_runs
        FOR EACH ROW EXECUTE FUNCTION folio_contract_allocations_immutable();

      CREATE TRIGGER contract_allocation_lines_immutable
        BEFORE UPDATE OR DELETE ON contract_allocation_lines
        FOR EACH ROW EXECUTE FUNCTION folio_contract_allocations_immutable();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS contract_allocation_lines_immutable ON contract_allocation_lines;
      DROP TRIGGER IF EXISTS contract_allocation_runs_immutable ON contract_allocation_runs;
      DROP FUNCTION IF EXISTS folio_contract_allocations_immutable();
    SQL
  end
end
