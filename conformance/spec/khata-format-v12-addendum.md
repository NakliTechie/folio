# `.khata` schema addendum — v6 → v12

> Reconciles [`khata-format.md`](khata-format.md) (which documents the on-disk format through
> **schema v5**) with the schema the reference implementation and this conformance corpus actually
> ship: **schema v12**, format version still **`1.0`**.

`khata-format.md` §4.6 stops at schema v5. Bahi's schema has since advanced to **v12** (see
`meta.schemaVersion` and `manifest.schemaVersion` in every corpus file, and `SCHEMA_VERSION = 12` in
Bahi's `sample-data/generator.py`). The format version is unchanged (`khataFormatVersion: "1.0"`) —
every v6→v12 change is **additive** (new columns via `ALTER TABLE ... ADD COLUMN`, new tables via
`CREATE TABLE IF NOT EXISTS`), exactly as §9's minor-version policy requires. A v5 reader ignoring the
new tables/columns still reads a v12 file correctly.

This addendum is authoritative for the corpus. The DDL below is dumped verbatim from
`corpus/files/pharma.khata` (the richest sample — it exercises every table).

## Columns added to v5 tables

| Table | Column | Notes |
|---|---|---|
| `audit_log` | `hash_version INTEGER` | Selects the hash preimage. `2` = the all-field v2 preimage (see [`canonical-json.md`](canonical-json.md)); legacy/absent = `sha256(prev_hash + origin + payload)`. All corpus rows are `hash_version = 2`. |
| `invoices` | `cess INTEGER NOT NULL DEFAULT 0` | GST compensation cess (paise). Present in the §4.2 v5 DDL narrative but formalised here. |
| `invoice_lines` | `cess INTEGER NOT NULL DEFAULT 0` | Per-line cess (paise). |

All monetary fields remain **INTEGER paise** (§4.1). Floating-point in posting paths is still forbidden.

## Schema version progression (extends §4.6)

| Version | Adds |
|---|---|
| 6 | `vendors`, `purchases`, `purchase_lines` (accounts-payable + ITC) |
| 7 | `credit_notes` / `credit_note_lines`, `debit_notes` / `debit_note_lines` |
| 8 | `tds_deductions`, `tcs_collections` |
| 9 | `godowns`, `batches`, `stock_movements` (inventory + batch valuation) |
| 10 | `delivery_challans` / `delivery_challan_lines`, `eway_bills`, `stock_transfers` |
| 11 | `period_locks`, `fy_closings` (return locking + year-end) |
| 12 | `annotations`, `review_markers`, `bank_reconciliations` (CA-mode review) + `audit_log.hash_version`, `invoices.cess`, `invoice_lines.cess` |

> The precise version at which each individual table first appeared is Bahi-internal migration
> history; the mapping above groups them by phase. What the contract pins is the **v12 end state** —
> the set of tables and columns a conforming v12 engine must materialise. A future engine need only
> reach the same end state, not replay Bahi's exact migration order.

## Tables added since v5 (authoritative DDL, dumped from the corpus)

```sql
CREATE TABLE vendors (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  gstin TEXT,
  pan TEXT,
  state TEXT,
  email TEXT,
  phone TEXT,
  address TEXT,
  rcm_applicable INTEGER DEFAULT 0,
  tds_section TEXT,
  opening_balance INTEGER DEFAULT 0,
  archived INTEGER DEFAULT 0,
  created_at TEXT NOT NULL
);

CREATE TABLE purchases (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bill_number TEXT NOT NULL,
  internal_ref TEXT NOT NULL UNIQUE,
  vendor_id INTEGER NOT NULL REFERENCES vendors(id),
  bill_date TEXT NOT NULL,
  due_date TEXT,
  place_of_supply TEXT,
  place_of_supply_name TEXT,
  is_import INTEGER DEFAULT 0,
  reverse_charge INTEGER DEFAULT 0,
  itc_eligible INTEGER DEFAULT 1,
  subtotal INTEGER NOT NULL DEFAULT 0,
  cgst INTEGER NOT NULL DEFAULT 0,
  sgst INTEGER NOT NULL DEFAULT 0,
  igst INTEGER NOT NULL DEFAULT 0,
  cess INTEGER NOT NULL DEFAULT 0,
  total INTEGER NOT NULL DEFAULT 0,
  notes TEXT,
  status TEXT NOT NULL DEFAULT 'posted',
  ledger_entry_id INTEGER REFERENCES entries(id),
  company_snapshot TEXT,
  vendor_snapshot TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE purchase_lines (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  purchase_id INTEGER NOT NULL REFERENCES purchases(id),
  line_no INTEGER NOT NULL,
  item_id INTEGER REFERENCES items(id),
  description TEXT NOT NULL,
  hsn_sac TEXT,
  hsn_description TEXT,
  quantity REAL NOT NULL DEFAULT 1,
  unit TEXT,
  rate INTEGER NOT NULL,
  discount INTEGER DEFAULT 0,
  taxable INTEGER NOT NULL,
  tax_rate REAL NOT NULL,
  rate_id TEXT,
  cgst INTEGER NOT NULL DEFAULT 0,
  sgst INTEGER NOT NULL DEFAULT 0,
  igst INTEGER NOT NULL DEFAULT 0,
  itc_eligible INTEGER DEFAULT 1,
  total INTEGER NOT NULL,
  cess INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE credit_notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  cn_number TEXT NOT NULL UNIQUE,
  cn_date TEXT NOT NULL,
  original_invoice_id INTEGER NOT NULL REFERENCES invoices(id),
  original_invoice_number TEXT NOT NULL,
  customer_id INTEGER NOT NULL REFERENCES customers(id),
  reason TEXT,
  place_of_supply TEXT,
  place_of_supply_name TEXT,
  subtotal INTEGER NOT NULL DEFAULT 0,
  cgst INTEGER NOT NULL DEFAULT 0,
  sgst INTEGER NOT NULL DEFAULT 0,
  igst INTEGER NOT NULL DEFAULT 0,
  total INTEGER NOT NULL DEFAULT 0,
  notes TEXT,
  status TEXT NOT NULL DEFAULT 'posted',
  ledger_entry_id INTEGER REFERENCES entries(id),
  company_snapshot TEXT,
  customer_snapshot TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE credit_note_lines (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  cn_id INTEGER NOT NULL REFERENCES credit_notes(id),
  line_no INTEGER NOT NULL,
  description TEXT NOT NULL,
  hsn_sac TEXT,
  hsn_description TEXT,
  quantity REAL NOT NULL DEFAULT 1,
  rate INTEGER NOT NULL,
  taxable INTEGER NOT NULL,
  tax_rate REAL NOT NULL,
  rate_id TEXT,
  cgst INTEGER NOT NULL DEFAULT 0,
  sgst INTEGER NOT NULL DEFAULT 0,
  igst INTEGER NOT NULL DEFAULT 0,
  total INTEGER NOT NULL
);

CREATE TABLE debit_notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  dn_number TEXT NOT NULL UNIQUE,
  dn_date TEXT NOT NULL,
  original_purchase_id INTEGER NOT NULL REFERENCES purchases(id),
  original_bill_number TEXT NOT NULL,
  vendor_id INTEGER NOT NULL REFERENCES vendors(id),
  reason TEXT,
  place_of_supply TEXT,
  place_of_supply_name TEXT,
  subtotal INTEGER NOT NULL DEFAULT 0,
  cgst INTEGER NOT NULL DEFAULT 0,
  sgst INTEGER NOT NULL DEFAULT 0,
  igst INTEGER NOT NULL DEFAULT 0,
  total INTEGER NOT NULL DEFAULT 0,
  notes TEXT,
  status TEXT NOT NULL DEFAULT 'posted',
  ledger_entry_id INTEGER REFERENCES entries(id),
  company_snapshot TEXT,
  vendor_snapshot TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE debit_note_lines (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  dn_id INTEGER NOT NULL REFERENCES debit_notes(id),
  line_no INTEGER NOT NULL,
  description TEXT NOT NULL,
  hsn_sac TEXT,
  hsn_description TEXT,
  quantity REAL NOT NULL DEFAULT 1,
  rate INTEGER NOT NULL,
  taxable INTEGER NOT NULL,
  tax_rate REAL NOT NULL,
  rate_id TEXT,
  cgst INTEGER NOT NULL DEFAULT 0,
  sgst INTEGER NOT NULL DEFAULT 0,
  igst INTEGER NOT NULL DEFAULT 0,
  total INTEGER NOT NULL
);

CREATE TABLE tds_deductions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  payment_id INTEGER REFERENCES payments(id),
  vendor_id INTEGER REFERENCES vendors(id),
  section TEXT NOT NULL,
  rate REAL NOT NULL,
  taxable_amount INTEGER NOT NULL,
  tds_amount INTEGER NOT NULL,
  payment_date TEXT NOT NULL,
  vendor_pan TEXT,
  vendor_name_snapshot TEXT,
  ledger_entry_id INTEGER REFERENCES entries(id),
  created_at TEXT NOT NULL
);

CREATE TABLE tcs_collections (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  invoice_id INTEGER REFERENCES invoices(id),
  customer_id INTEGER REFERENCES customers(id),
  section TEXT NOT NULL,
  rate REAL NOT NULL,
  taxable_amount INTEGER NOT NULL,
  tcs_amount INTEGER NOT NULL,
  invoice_date TEXT NOT NULL,
  customer_pan TEXT,
  customer_name_snapshot TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE godowns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  address TEXT,
  state TEXT,
  is_default INTEGER DEFAULT 0,
  archived INTEGER DEFAULT 0,
  created_at TEXT NOT NULL
);

CREATE TABLE batches (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id INTEGER NOT NULL REFERENCES items(id),
  godown_id INTEGER NOT NULL REFERENCES godowns(id),
  batch_no TEXT,
  mfg_date TEXT,
  expiry_date TEXT,
  source_purchase_id INTEGER REFERENCES purchases(id),
  source_purchase_line_id INTEGER REFERENCES purchase_lines(id),
  qty_in INTEGER NOT NULL DEFAULT 0,
  qty_out INTEGER NOT NULL DEFAULT 0,
  qty_balance INTEGER NOT NULL DEFAULT 0,
  rate INTEGER NOT NULL,
  value_in INTEGER NOT NULL DEFAULT 0,
  value_out INTEGER NOT NULL DEFAULT 0,
  value_balance INTEGER NOT NULL DEFAULT 0,
  is_wac_synthetic INTEGER DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'open',
  notes TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE stock_movements (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id INTEGER NOT NULL REFERENCES items(id),
  godown_id INTEGER NOT NULL REFERENCES godowns(id),
  batch_id INTEGER REFERENCES batches(id),
  movement_type TEXT NOT NULL,
  voucher_type TEXT NOT NULL,
  voucher_id INTEGER,
  voucher_ref TEXT,
  posted_at TEXT NOT NULL,
  qty INTEGER NOT NULL,
  rate INTEGER NOT NULL,
  value INTEGER NOT NULL,
  item_name_snapshot TEXT,
  unit_snapshot TEXT,
  godown_name_snapshot TEXT,
  notes TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE delivery_challans (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  challan_number TEXT NOT NULL UNIQUE,
  challan_date TEXT NOT NULL,
  challan_type TEXT NOT NULL,
  customer_id INTEGER REFERENCES customers(id),
  vendor_id INTEGER REFERENCES vendors(id),
  godown_id INTEGER NOT NULL REFERENCES godowns(id),
  destination TEXT,
  vehicle_no TEXT,
  transporter TEXT,
  reason TEXT,
  is_returnable INTEGER DEFAULT 0,
  expected_return_date TEXT,
  linked_invoice_id INTEGER REFERENCES invoices(id),
  status TEXT NOT NULL DEFAULT 'open',
  company_snapshot TEXT,
  party_snapshot TEXT,
  notes TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE delivery_challan_lines (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  challan_id INTEGER NOT NULL REFERENCES delivery_challans(id),
  line_no INTEGER NOT NULL,
  item_id INTEGER NOT NULL REFERENCES items(id),
  description TEXT NOT NULL,
  quantity INTEGER NOT NULL,
  unit TEXT,
  batch_id INTEGER REFERENCES batches(id),
  rate INTEGER,
  notes TEXT
);

CREATE TABLE eway_bills (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ewb_number TEXT,
  ewb_date TEXT NOT NULL,
  source_type TEXT NOT NULL,
  source_id INTEGER NOT NULL,
  source_ref TEXT NOT NULL,
  transporter_name TEXT,
  transporter_id TEXT,
  vehicle_no TEXT,
  vehicle_type TEXT,
  mode TEXT,
  distance_km INTEGER,
  reason_code TEXT,
  supplier_snapshot TEXT,
  recipient_snapshot TEXT,
  goods_snapshot TEXT,
  taxable_value INTEGER NOT NULL,
  cgst INTEGER NOT NULL DEFAULT 0,
  sgst INTEGER NOT NULL DEFAULT 0,
  igst INTEGER NOT NULL DEFAULT 0,
  cess INTEGER NOT NULL DEFAULT 0,
  total INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'draft',
  notes TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE stock_transfers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  transfer_number TEXT NOT NULL UNIQUE,
  transfer_date TEXT NOT NULL,
  direction TEXT NOT NULL,
  from_gstin TEXT NOT NULL,
  from_state TEXT NOT NULL,
  to_gstin TEXT NOT NULL,
  to_state TEXT NOT NULL,
  from_godown_id INTEGER REFERENCES godowns(id),
  to_godown_id INTEGER REFERENCES godowns(id),
  linked_invoice_id INTEGER REFERENCES invoices(id),
  linked_purchase_id INTEGER REFERENCES purchases(id),
  ewb_id INTEGER REFERENCES eway_bills(id),
  total_value INTEGER NOT NULL,
  payload_snapshot TEXT,
  status TEXT NOT NULL DEFAULT 'draft',
  notes TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE period_locks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  return_type TEXT NOT NULL,
  period_start TEXT NOT NULL,
  period_end TEXT NOT NULL,
  filed_at TEXT NOT NULL,
  filed_by TEXT,
  notes TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE fy_closings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fy_start TEXT NOT NULL,
  fy_end TEXT NOT NULL,
  closed_at TEXT NOT NULL,
  closing_entry_id INTEGER REFERENCES entries(id),
  net_profit INTEGER NOT NULL DEFAULT 0,
  carried_forward INTEGER NOT NULL DEFAULT 0,
  notes TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE annotations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  target_type TEXT NOT NULL,
  target_id INTEGER NOT NULL,
  target_ref TEXT,
  note_type TEXT NOT NULL,
  body TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open',
  ca_name TEXT,
  ca_firm TEXT,
  ca_membership TEXT,
  created_at TEXT NOT NULL,
  created_by TEXT NOT NULL,
  resolved_at TEXT,
  resolved_by TEXT
);

CREATE TABLE review_markers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  entry_id INTEGER NOT NULL REFERENCES entries(id),
  reviewed_at TEXT NOT NULL,
  reviewed_by TEXT NOT NULL,
  ca_membership TEXT,
  notes TEXT
);

CREATE TABLE bank_reconciliations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bank_account_id INTEGER NOT NULL REFERENCES accounts(id),
  reconciled_through_date TEXT NOT NULL,
  closing_balance_per_book INTEGER NOT NULL,
  closing_balance_per_statement INTEGER NOT NULL,
  uncleared_debits INTEGER DEFAULT 0,
  uncleared_credits INTEGER DEFAULT 0,
  difference INTEGER DEFAULT 0,
  matched_entry_lines TEXT,
  notes TEXT,
  reconciled_at TEXT NOT NULL,
  reconciled_by TEXT NOT NULL
);
```

## Snapshot / historical-integrity columns extend to the new documents

The §8.1 invariants apply to every posted document, including the v6+ ones: `purchases` and
`debit_notes` freeze `company_snapshot` + `vendor_snapshot`; `credit_notes` freeze
`company_snapshot` + `customer_snapshot`; `purchase_lines` / `credit_note_lines` /
`debit_note_lines` freeze `hsn_description` + `rate_id` + `tax_rate`; `stock_movements` freeze
`item_name_snapshot` / `unit_snapshot` / `godown_name_snapshot`. A reprint path for any of these
MUST read the frozen columns, never re-JOIN the live master.
