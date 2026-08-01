# frozen_string_literal: true

module Folio
  # Deterministic synthetic-book generator — Folio's native answer to Bahi's
  # sample-data/generator.py. It drives Folio's REAL domain services (Onboarding,
  # Parties, Items, SalesInvoices, PurchaseBills, Settlements) to seed a realistic,
  # fully-posted tenant. Because it posts through the same engine a user does, a seeded
  # book is a live cross-check of the accounting AND regulatory paths — the "independent
  # clean build, Bahi as oracle" posture: Folio's own output should match Bahi's.
  #
  # Everything is fixed (dates, amounts, names) — no clocks, no randomness — so the same
  # scenario yields the same books every run. Seeds a fresh tenant per run (multi-tenant),
  # so re-running with a new email is how you get a clean demo; a repeated email raises.
  #
  # Feeds /demo-nt, /walkthrough-nt, /guide-nt, and can back model tests.
  module SampleBooks
    Error = Class.new(StandardError)

    # A party (customer or vendor) master to create.
    Party = Data.define(:ref, :name, :state_code, :city, :postal_code, :pan)
    # A service master. rate_basis_points is GST (e.g. 1800 = 18%).
    Service = Data.define(:code, :name, :hsn_sac_code, :rate_basis_points)
    # A sales invoice to build+post. qty/unit_price are decimal STRINGS (rupees).
    Sale = Data.define(:ref, :customer_ref, :service_code, :date, :due_date, :quantity, :unit_price)
    # A purchase bill. supplier_ref is the vendor's own invoice no (required, unique per vendor).
    # tds_section (optional) tags a payment that a TDS lifecycle would withhold on — the
    # generator computes a TDS preview with the shipped kernel but does not post the leg yet.
    Purchase = Data.define(:ref, :vendor_ref, :service_code, :date, :due_date,
                           :quantity, :unit_price, :supplier_ref, :tds_section)
    # A receipt/payment against a posted sale/purchase. amount a decimal STRING; mode is
    # "partial" or "residual".
    Receipt = Data.define(:sale_ref, :date, :amount, :mode)
    Payment = Data.define(:purchase_ref, :date, :amount, :mode)

    # A whole book to seed. home_* is the company's own registered place of business.
    Scenario = Data.define(
      :code, :org_name, :home_state, :home_jurisdiction, :home_city, :home_postal_code,
      :company_pan, :customers, :vendors, :services, :sales, :purchases, :receipts, :payments
    )

    # --- Scenario library --------------------------------------------------------------
    # A Maharashtra services firm across the first quarter of FY 2026-27, with intra-state
    # (MH/27, CGST+SGST) and inter-state (KA/29, IGST) customers, two vendors (one a 194C
    # subcontractor), and a spread of receipts/payments incl. partial and residual clearing.
    CONSULTING = Scenario.new(
      code: "consulting",
      org_name: "Meridian Consulting LLP",
      home_state: "27", home_jurisdiction: "IN-MH", home_city: "Mumbai", home_postal_code: "400001",
      company_pan: "AAPCM4567L",
      customers: [
        Party.new("C-001", "Sundara Retail Pvt Ltd", "27", "Pune", "411001", "AAACS1234F"),
        Party.new("C-002", "Kaveri Textiles Ltd",   "29", "Bengaluru", "560002", "AABCK5678G"),
        Party.new("C-003", "Deccan Foods LLP",       "27", "Nashik", "422001", "AAECD9012H")
      ],
      vendors: [
        Party.new("V-001", "Nilgiri Subcontractors", "29", "Mysuru", "570001", "AABFN3456J"),
        Party.new("V-002", "Pinnacle Office Services", "27", "Mumbai", "400051", "AAFCP7890K")
      ],
      services: [
        Service.new("CONSULT",  "Management consulting", "998311", 1800),
        Service.new("TECH",     "Technical advisory",    "998313", 1800),
        Service.new("TRAINING", "Corporate training",    "999293", 1800)
      ],
      sales: [
        Sale.new("INV1", "C-001", "CONSULT",  Date.new(2026, 4, 15), Date.new(2026, 5, 15), "10", "5000.00"),
        Sale.new("INV2", "C-002", "TECH",     Date.new(2026, 5, 10), Date.new(2026, 6, 9),  "8",  "6000.00"),
        Sale.new("INV3", "C-003", "TRAINING", Date.new(2026, 5, 20), Date.new(2026, 6, 19), "5",  "4000.00"),
        Sale.new("INV4", "C-001", "CONSULT",  Date.new(2026, 6, 12), Date.new(2026, 7, 12), "12", "5000.00"),
        Sale.new("INV5", "C-002", "CONSULT",  Date.new(2026, 6, 28), Date.new(2026, 7, 28), "6",  "6500.00")
      ],
      purchases: [
        Purchase.new("BILL1", "V-001", "CONSULT", Date.new(2026, 5, 5), Date.new(2026, 6, 4),
                     "8", "5000.00", "NS-2026-114", "194C"),
        Purchase.new("BILL2", "V-002", "TECH", Date.new(2026, 6, 1), Date.new(2026, 7, 1),
                     "1", "15000.00", "POS-0442", nil)
      ],
      receipts: [
        # INV1 (₹59,000): part payment, ₹29,000 stays open and ages.
        Receipt.new("INV1", Date.new(2026, 5, 1), "30000.00", "partial"),
        # INV2 (₹56,640): received in full.
        Receipt.new("INV2", Date.new(2026, 6, 5), "56640.00", "partial"),
        # INV3 (₹23,600): ₹20,000 received, ₹3,600 short-closed via residual re-baseline.
        Receipt.new("INV3", Date.new(2026, 6, 25), "20000.00", "residual")
      ],
      payments: [
        Payment.new("BILL1", Date.new(2026, 6, 4), "47200.00", "partial")
      ]
    )

    SCENARIOS = { CONSULTING.code => CONSULTING }.freeze

    module_function

    # Seed a scenario into a fresh tenant. Returns Generator::Result.
    def seed!(scenario: "consulting", email:, password: "sample-books-2026")
      scen = scenario.is_a?(Scenario) ? scenario : SCENARIOS.fetch(scenario) do
        raise Error, "unknown scenario #{scenario.inspect} — known: #{SCENARIOS.keys.join(', ')}"
      end
      Generator.new(scenario: scen, email: email, password: password).run
    end
  end
end
