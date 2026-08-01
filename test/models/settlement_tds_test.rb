# frozen_string_literal: true

require "test_helper"

# The TDS lifecycle at the posting layer (7L.3): a vendor payment withholds tax and posts the
# 3-way split (Dr AP gross / Cr Bank net / Cr TDS Payable), recording a frozen TdsDeduction.
class SettlementTdsTest < ActiveSupport::TestCase
  PAY_DATE = Date.new(2026, 8, 20)
  VENDOR_PAN = "AABFN3456J" # 4th char F = firm → 194C "other" leg (2%)

  setup do
    @org = Onboarding::SignUp.call(
      email: "settlement-tds@folio.invalid", password: "correct-horse-battery-staple",
      org_name: "TDS Model"
    )
    entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    office.update!(address_line1: "1 Ledger Lane", city: "Mumbai", postal_code: "400001",
                   state_code: "27", country_code: "IN")
    @registration = TaxRegistrations::Manage.create!(
      tenant: @org.tenant, entity: entity,
      attributes: { kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
                    valid_from: Date.new(2026, 4, 1) },
      office_ids: [ office.id ], actor: @org.user
    )
    vendor_gstin = "29#{VENDOR_PAN}1Z#{Taxes::India::Gstin.checksum("29#{VENDOR_PAN}1Z")}"
    @vendor = Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: { party_number: "V-001", name: "Nilgiri Subcontractors", state_code: "29",
                    country_code: "IN", address_line1: "1 Vendor Rd", city: "Mysuru",
                    postal_code: "570001", default_tds_section: "194C" },
      roles: [ "vendor" ],
      tax_registration_attributes: { kind: "GSTIN", identifier: vendor_gstin, valid_from: Date.new(2026, 4, 1) },
      actor: @org.user
    )
    @service = Items::Manage.create!(
      tenant: @org.tenant,
      attributes: { code: "JOBWORK", name: "Machining job work", item_type: "service",
                    hsn_sac_code: "998898", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
                    cess_rate_basis_points: 0, income_account_code: "4000", expense_account_code: "5000" },
      actor: @org.user
    )
    @bill = PurchaseBills::BuildDraft.call(
      tenant: @org.tenant, party_id: @vendor.id, tax_registration_id: @registration.id,
      document_date: Date.new(2026, 8, 1), due_date: Date.new(2026, 8, 31),
      place_of_supply_state_code: "27", external_reference: "NS-114",
      lines: [ { item_id: @service.id, quantity: "8", unit_price: "5000.00" } ]
    )
    Documents::Post.call(@bill, actor: "u:#{@org.user.id}")
    @payable = EntryLine.joins(:entry).find_by!(entries: { document_id: @bill.id }, account_code: "2000")
    @gross = Posting::Clearing.open_amount(@payable)
  end

  def pay!(amount_minor, tds_section: nil)
    draft = Settlements::BuildDraft.call(
      tenant: @org.tenant, doc_type: "PY", document_date: PAY_DATE, bank_account_code: "1010",
      tds_section: tds_section,
      allocations: [ { target_entry_line_id: @payable.id, amount: format("%.2f", amount_minor / 100.0),
                       clearing_mode: "partial" } ]
    )
    Documents::Post.call(draft, actor: "u:#{@org.user.id}")
  end

  test "a vendor payment with a default TDS section posts the 3-way split" do
    expected = Taxes::India::Tds::Deduction.compute(
      section: "194C", on: PAY_DATE, amount_minor: @gross, pan: VENDOR_PAN
    )
    assert expected.applied
    assert_equal 200, expected.rate_basis_points # firm → 2%

    entry = pay!(@gross)
    lines = entry.entry_lines.order(:line_no).map do |line|
      [ line.account_code, line.amounts.find_by!(slot_role: "transaction").amount_minor ]
    end
    # Dr AP (gross, +) · Cr Bank (net, −) · Cr TDS Payable (tds, −)
    assert_equal [ "1010", -(@gross - expected.tds_minor) ], lines.find { |c, _| c == "1010" }
    assert_equal [ "2000", @gross ], lines.find { |c, _| c == "2000" }
    assert_equal [ "2110", -expected.tds_minor ], lines.find { |c, _| c == "2110" }

    tb = Reports.trial_balance(@org.tenant.id)
    assert_equal tb.sum { |r| r.fetch("debit") }, tb.sum { |r| r.fetch("credit") }
  end

  test "the payment records a frozen TdsDeduction" do
    expected = Taxes::India::Tds::Deduction.compute(section: "194C", on: PAY_DATE, amount_minor: @gross, pan: VENDOR_PAN)
    entry = pay!(@gross)

    d = TdsDeduction.for_tenant(@org.tenant.id).sole
    assert_equal "194C", d.section
    assert_equal 200, d.rate_basis_points
    assert_equal @gross, d.taxable_minor
    assert_equal expected.tds_minor, d.tds_minor
    assert_equal @vendor.id, d.party_id
    assert_equal "Nilgiri Subcontractors", d.deductee_name_snapshot
    assert_equal VENDOR_PAN, d.deductee_pan
    assert_equal entry.document_id, d.source_document_id
    assert_equal entry.id, d.entry_id
    assert_equal 2026, d.fiscal_year
    assert_equal 2, d.quarter # August → Q2
  end

  test "the AP open item still clears the full gross despite the net cash outflow" do
    pay!(@gross)
    assert_equal 0, Posting::Clearing.open_amount(EntryLine.find(@payable.id))
  end

  test "a payment below the threshold withholds nothing and posts the plain 2-way split" do
    # A tiny second bill under ₹30,000 gross, paid on its own (the setup's large bill is left open).
    bill = PurchaseBills::BuildDraft.call(
      tenant: @org.tenant, party_id: @vendor.id, tax_registration_id: @registration.id,
      document_date: Date.new(2026, 8, 2), due_date: Date.new(2026, 8, 31),
      place_of_supply_state_code: "27", external_reference: "NS-115",
      lines: [ { item_id: @service.id, quantity: "1", unit_price: "5000.00" } ]
    )
    Documents::Post.call(bill, actor: "u:#{@org.user.id}")
    payable = EntryLine.joins(:entry).find_by!(entries: { document_id: bill.id }, account_code: "2000")
    gross = Posting::Clearing.open_amount(payable)

    draft = Settlements::BuildDraft.call(
      tenant: @org.tenant, doc_type: "PY", document_date: PAY_DATE, bank_account_code: "1010",
      allocations: [ { target_entry_line_id: payable.id, amount: format("%.2f", gross / 100.0),
                       clearing_mode: "partial" } ]
    )
    entry = Documents::Post.call(draft, actor: "u:#{@org.user.id}")
    assert_equal 2, entry.entry_lines.count, "below-threshold payment stays 2-line"
    assert_equal 0, TdsDeduction.for_tenant(@org.tenant.id).count, "nothing withheld below threshold"
  end
end
