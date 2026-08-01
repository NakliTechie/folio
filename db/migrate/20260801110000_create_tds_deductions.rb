# frozen_string_literal: true

# TDS lifecycle 7L.1 — the record of tax withheld at source on a vendor payment.
#
# This is DERIVED, FROZEN evidence, not a ledger line: the authoritative posting is the
# 3-way entry on ledger_events (Dr AP / Cr Bank net / Cr TDS Payable). A tds_deductions row
# captures what was withheld, for the Form 26Q return and the Form 16A certificate.
#
# Deliberately NOT append-only-triggered (it is a projection over the ledger, rebuildable),
# and it holds SOFT references (plain bigints, no DB foreign keys) to party/document/entry —
# same master-independent-replay discipline as ledger_events (history.md 2026-07-31). The
# deductee PAN and name are FROZEN on the row so a certificate reprints correctly even after
# the party master changes (Folio's snapshot pattern + Bahi's frozen columns).
class CreateTdsDeductions < ActiveRecord::Migration[8.1]
  def up
    create_table :tds_deductions do |t|
      t.bigint  :tenant_id,          null: false
      t.bigint  :party_id,           null: false   # deductee (vendor) — soft reference
      t.string  :section,            null: false   # e.g. "194C" (a Schedule section)
      t.integer :rate_basis_points,  null: false   # the effective rate applied
      t.bigint  :taxable_minor,      null: false   # base TDS was computed on
      t.bigint  :tds_minor,          null: false   # tax actually withheld
      t.date    :deduction_date,     null: false
      t.string  :deductee_pan                       # frozen; may be nil (§206AA case)
      t.string  :deductee_name_snapshot, null: false # frozen at deduction time
      t.bigint  :source_document_id, null: false    # the payment Document — soft reference
      t.bigint  :entry_id                           # the posted Entry — soft reference
      t.integer :fiscal_year,        null: false    # India FY start year (Apr–Mar)
      t.integer :quarter,            null: false    # 1..4 (Q1 Apr–Jun … Q4 Jan–Mar)

      t.timestamps
    end

    add_index :tds_deductions, [ :tenant_id, :party_id ]
    add_index :tds_deductions, [ :tenant_id, :fiscal_year, :quarter ]
    add_index :tds_deductions, [ :tenant_id, :section ]
    add_index :tds_deductions, :source_document_id

    execute <<~SQL
      ALTER TABLE tds_deductions
        ADD CONSTRAINT tds_deductions_quarter_valid CHECK (quarter BETWEEN 1 AND 4),
        ADD CONSTRAINT tds_deductions_amounts_nonneg CHECK (taxable_minor >= 0 AND tds_minor >= 0);
    SQL

    # The vendor's default TDS section (Bahi's vendor-master field). A payment may override it;
    # nil means the vendor is not ordinarily subject to withholding.
    add_column :parties, :default_tds_section, :string
  end

  def down
    remove_column :parties, :default_tds_section
    drop_table :tds_deductions
  end
end
