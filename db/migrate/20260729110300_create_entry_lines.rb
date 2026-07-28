# frozen_string_literal: true

# B3.1 — entry_lines, the committed dimension set (spec §3; decisions D1, D2, D3, D5, D7, D12).
#
# HYBRID dimensions (owner answer Q3): committed dimensions are REAL TYPED COLUMNS here;
# the `dimensions` registry (B3.0) governs derivation/requiredness/validation; `extra`
# jsonb holds uncommitted dimensions and is NEVER aggregated in a statutory report.
#
# Amounts do NOT live here — they are in journal_entry_line_amounts (D4 child table), so a
# line can carry transaction/functional/group slots without widening this row.
#
# D15 is load-bearing: when these columns feed the event payload, an absent one is OMITTED,
# never serialised as null. Widening this table additively contributes nothing to the hash
# preimage (the serialiser walks only present keys), so Tier C still reproduces the corpus.
class CreateEntryLines < ActiveRecord::Migration[8.1]
  def change
    create_table :entry_lines do |t|
      t.bigint  :tenant_id,   null: false
      t.bigint  :entry_id,    null: false
      t.integer :line_no,     null: false                      # stable, never reused within (entry, ledger)
      t.string  :account_code, null: false                     # accounts by STABLE CODE (§9 fat events)

      # --- D1: ledger multiplicity — balance is per (entry, ledger), never global ---
      t.bigint  :ledger_id,   null: false

      # --- D3: org spine on the line ---
      t.bigint  :entity_id,           null: false
      t.bigint  :office_id,           null: false
      t.bigint  :tax_registration_id                           # on tax-relevant lines

      # --- D2: committed typed dimensions ---
      t.string  :cost_object_type                              # cost_center / order / project / ...
      t.bigint  :cost_object_id
      t.bigint  :profit_center_id                              # dummy member if underivable
      t.bigint  :segment_id                                    # unassigned member if underivable
      t.bigint  :functional_area_id
      t.string  :line_class,   null: false, default: "real"    # real / statistical
      t.string  :posting_layer, null: false, default: "00"     # v1 always 00

      # --- D3 / allocations / intercompany: partner side, matched by construction ---
      t.bigint  :partner_entity_id
      t.bigint  :partner_profit_center_id
      t.bigint  :partner_segment_id
      t.string  :partner_cost_object_type
      t.bigint  :partner_cost_object_id
      t.string  :intercompany_transaction_id                   # shared id → two balanced entries, no matching engine

      # --- D12: parties spine (not vendor_id/customer_id) ---
      t.bigint  :party_id
      t.string  :party_role                                    # customer / vendor / employee / ...

      # --- stock lines ---
      t.bigint  :item_id
      t.bigint  :warehouse_id
      t.decimal :quantity, precision: 20, scale: 6
      t.string  :uom
      t.string  :movement_type                                 # on balance-sheet stock lines

      # --- D5: open items and clearing ---
      t.boolean :open_item, null: false, default: false        # from account_entity_settings at post
      t.string  :item_class                                    # normal / down_payment / statistical / noted
      t.string  :assignment                                    # the clearing key
      t.date    :baseline_date                                 # drives ageing
      t.bigint  :cleared_by_entry_id                           # written by the clearing document (B3.3)
      t.date    :cleared_on
      t.bigint  :reconciliation_gl_account_id                  # resolved and frozen at posting
      t.date    :due_date                                      # payment-term outcomes frozen at posting
      t.decimal :discount_pct, precision: 7, scale: 4
      t.date    :discount_date

      # --- bank lines ---
      t.date    :value_date                                    # .khata v1.1 change (khata-v1.1-proposal.md)

      # --- D7: reversal semantics ---
      t.boolean :is_negative_posting, null: false, default: false  # unrecoverable without this one boolean

      # --- reserved in v1 (specified now so replay never has to invent them) ---
      t.bigint  :split_source_line_id                          # document-splitting provenance
      t.string  :split_kind
      t.bigint  :liquidity_item_id
      t.jsonb   :cost_component_split                          # cost-component vector
      t.string  :valuation_view

      # --- D2: the uncommitted-dimension bag — NEVER aggregated in a statutory report ---
      t.jsonb   :extra

      t.timestamps
    end

    add_index :entry_lines, :entry_id
    add_index :entry_lines, [ :entry_id, :ledger_id, :line_no ], unique: true,
      name: "index_entry_lines_on_entry_ledger_line_no"
    add_index :entry_lines, :ledger_id
    add_index :entry_lines, :party_id
    add_index :entry_lines, [ :tenant_id, :assignment ],
      where: "assignment IS NOT NULL", name: "index_entry_lines_on_clearing_key"
    add_index :entry_lines, [ :tenant_id, :account_code ]
  end
end
