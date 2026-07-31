# frozen_string_literal: true

class PreventOverlappingPartyTaxRegistrations < ActiveRecord::Migration[8.1]
  def up
    enable_extension "btree_gist" unless extension_enabled?("btree_gist")
    execute <<~SQL
      ALTER TABLE party_tax_registrations
      ADD CONSTRAINT party_tax_registrations_no_active_overlap
      EXCLUDE USING gist (
        party_id WITH =,
        kind WITH =,
        daterange(valid_from, COALESCE(valid_to, 'infinity'::date), '[]') WITH &&
      ) WHERE (active);
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE party_tax_registrations
      DROP CONSTRAINT IF EXISTS party_tax_registrations_no_active_overlap;
    SQL
  end
end
