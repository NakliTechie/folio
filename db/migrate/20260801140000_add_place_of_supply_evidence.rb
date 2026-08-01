# frozen_string_literal: true

class AddPlaceOfSupplyEvidence < ActiveRecord::Migration[8.1]
  def up
    add_column :documents, :place_of_supply_evidence, :jsonb, null: false, default: {}

    execute <<~SQL.squish
      UPDATE documents
      SET place_of_supply_evidence = jsonb_strip_nulls(jsonb_build_object(
        'basis', CASE
          WHEN party_snapshot->>'stateCode' = place_of_supply_state_code THEN 'party_address'
          ELSE 'legacy_explicit'
        END,
        'selectedStateCode', place_of_supply_state_code,
        'partyStateCode', party_snapshot->>'stateCode',
        'reason', CASE
          WHEN party_snapshot->>'stateCode' <> place_of_supply_state_code
            THEN 'Recorded before Folio required structured override evidence'
          ELSE NULL
        END,
        'recordedAt', created_at
      ))
      WHERE place_of_supply_state_code IS NOT NULL
    SQL
  end

  def down
    remove_column :documents, :place_of_supply_evidence
  end
end
