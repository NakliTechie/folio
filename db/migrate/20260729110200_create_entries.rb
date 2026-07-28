# frozen_string_literal: true

# B3.1 — the accounting entry header (spec §6, §7, §8, §11; decisions D6, D7, D13).
#
# `entries` is the accounting document header — it carries the four dates and the STORED
# period identity. `documents` (separate table) is the numbering/identity object; an entry
# references a document once the document layer (Batch 4) is built, so document_id is
# nullable in v1 (a run is also a valid document origin — spec §8 — so it must stay
# nullable).
#
# FOUR DATES, not two. period_no is STORED, never derived from posting_date: periods 13-16
# share period 12's date range by user choice, and period 0 (carryforward) has no range —
# both are unrecoverable from the date. period_no ∈ {0} ∪ [1..16] enforced by CHECK.
#
# REVERSAL LINKAGE placement — spec §7's table lists reverses_id/reversed_by_id under
# "document"; I place them on `entries` instead (matching the Batch 3 workplan and the
# natural accounting-entry semantics — an entry reverses another entry). This is
# projection metadata, NOT in the hash preimage, so it is reversible by ordinary migration
# while never-degrade #1 holds. Logged as an assumption in history.md.
#
# AUTHORITY (D13, payload half): role_template_id / posting_limit_id record the authority
# a post was made under — "was this person permitted to post this, at this amount, at that
# time?" — not merely who posted. The RBAC matrix TABLES (role_templates etc.) are M2.
class CreateEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :entries do |t|
      t.bigint  :tenant_id,   null: false
      t.bigint  :document_id                                   # nullable: run-origin postings (§8)
      t.bigint  :ledger_event_id                               # the immutable event this projects from

      # --- D6: four dates, not two ---
      t.date     :document_date, null: false                   # payment terms + GST period
      t.date     :posting_date,  null: false                   # period, FX rate, period-lock target
      t.datetime :entered_at,    null: false                   # wall clock; the 31-Mar/12-Apr audit tell

      # --- D6: STORED period identity ---
      t.integer :fiscal_year, null: false
      t.integer :period_no,   null: false                      # {0} ∪ [1..12] ∪ [13..16]

      # --- D7: reversal linkage (append-only forces the pair; see class note on placement) ---
      t.bigint :reverses_id                                    # this entry reverses that one
      t.bigint :reversed_by_id                                 # ... and was reversed by that one
      t.bigint :reversal_reason_id                             # versioned config; gates is_negative_posting
      t.date   :alternative_posting_date                       # when the original period is locked

      # --- D13: recorded authority (payload half; matrix tables are M2) ---
      t.bigint :role_template_id
      t.bigint :posting_limit_id

      t.timestamps
    end
    add_index :entries, [ :tenant_id, :fiscal_year, :period_no ]
    add_index :entries, :document_id
    add_index :entries, :ledger_event_id
    add_index :entries, :reverses_id

    # period_no domain — special periods and carryforward are real, so allow 0..16.
    execute <<~SQL
      ALTER TABLE entries ADD CONSTRAINT chk_entries_period_no
        CHECK (period_no >= 0 AND period_no <= 16)
    SQL
  end
end
