# frozen_string_literal: true

require "test_helper"

# TDS is assessed at the supplier-invoice credit event. The later payment clears the already
# net vendor payable and must never deduct the same tax a second time.
class SettlementTdsTest < ActiveSupport::TestCase
  PAY_DATE = Date.new(2026, 8, 20)
  VENDOR_PAN = "AABFN3456J" # 4th char F = firm → contractor "other" leg (2%)

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
      tax_registration_attributes: { kind: "GSTIN", identifier: vendor_gstin,
                                     valid_from: Date.new(2026, 4, 1) },
      actor: @org.user
    )
    @service = Items::Manage.create!(
      tenant: @org.tenant,
      attributes: { code: "JOBWORK", name: "Machining job work", item_type: "service",
                    hsn_sac_code: "998898", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
                    cess_rate_basis_points: 0, income_account_code: "4000", expense_account_code: "5000" },
      actor: @org.user
    )
    @bill = build_bill(reference: "NS-114", date: Date.new(2026, 8, 1), amount: "5000.00", quantity: "8")
    @bill_entry = Documents::Post.call(@bill, actor: "u:#{@org.user.id}")
    @payable = @bill_entry.entry_lines.find_by!(account_code: "2000")
    @net_payable = Posting::Clearing.open_amount(@payable)
  end

  def pay!(amount_minor = @net_payable, tds_section: nil)
    draft = Settlements::BuildDraft.call(
      tenant: @org.tenant, doc_type: "PY", document_date: PAY_DATE, bank_account_code: "1010",
      tds_section: tds_section,
      allocations: [ { target_entry_line_id: @payable.id,
                       amount: format("%.2f", amount_minor / 100.0), clearing_mode: "partial" } ]
    )
    Documents::Post.call(draft, actor: "u:#{@org.user.id}")
  end

  test "the purchase bill credits net AP and TDS payable on its GST-exclusive base" do
    assert_equal 4_000_000, @bill.subtotal_minor
    assert_equal 720_000, @bill.tax_minor
    assert_equal 80_000, @bill.tds_minor
    assert_equal 4_000_000, @bill.tds_taxable_minor
    assert_equal "credit", @bill.tds_trigger_event
    assert_equal "invoice_excluding_separately_stated_gst", @bill.tds_base_basis
    assert_equal "Income-tax Act 2025 §393(1), Table Sl. 6(i)", @bill.tds_statutory_reference

    amounts = @bill_entry.entry_lines.order(:line_no).to_h do |line|
      [ line.account_code, line.amounts.find_by!(slot_role: "transaction").amount_minor ]
    end
    assert_equal(-4_640_000, amounts.fetch("2000"))
    assert_equal 4_000_000, amounts.fetch("5000")
    input_gst = @bill_entry.entry_lines.where(account_code: "1210").to_a.sum do |line|
      line.amounts.find_by!(slot_role: "transaction").amount_minor
    end
    assert_equal 720_000, input_gst
    assert_equal(-80_000, amounts.fetch("2110"))
    assert Documents::Simulate.call(@bill).fetch(:balanced)
  end

  test "posting the bill records complete frozen TDS evidence" do
    deduction = TdsDeduction.for_tenant(@org.tenant.id).sole
    assert_equal "deduction", deduction.kind
    assert_equal "194C", deduction.section
    assert_equal 200, deduction.rate_basis_points
    assert_equal 4_720_000, deduction.gross_minor
    assert_equal 720_000, deduction.gst_minor
    assert_equal 4_000_000, deduction.taxable_minor
    assert_equal 4_000_000, deduction.deductible_base_minor
    assert_equal 80_000, deduction.tds_minor
    assert_equal @bill.id, deduction.source_document_id
    assert_equal @bill_entry.id, deduction.entry_id
    assert_equal @bill_entry.ledger_event_id, deduction.ledger_event_id
    assert_equal VENDOR_PAN, deduction.deductee_pan
    assert_equal 2026, deduction.fiscal_year
    assert_equal 2, deduction.quarter
  end

  test "TDS evidence survives projection rebuild and is bound to the fat event" do
    deduction = TdsDeduction.for_tenant(@org.tenant.id).sole
    event = LedgerEvent.find(@bill_entry.ledger_event_id)
    assert_equal @bill.id, JSON.parse(event.payload).dig(
      "statutoryEvidence", "tdsDeduction", "sourceDocumentId"
    )

    Posting.rebuild!(@org.tenant.id)

    assert_equal deduction.id, TdsDeduction.for_tenant(@org.tenant.id).sole.id
    assert_equal 80_000,
      Reports.tds_return_26q(@org.tenant.id, fiscal_year: 2026, quarter: 2).fetch("total_tds_minor")
  end

  test "an earlier TDS bill cannot be reversed while a later assessment depends on it" do
    later = build_bill(reference: "NS-116", date: Date.new(2026, 8, 2), amount: "5000.00")
    Documents::Post.call(later, actor: "u:#{@org.user.id}")

    error = assert_raises(Documents::Reverse::NotReversible) do
      Documents::Reverse.call(@bill, actor: "u:#{@org.user.id}", on: Date.new(2026, 8, 3))
    end

    assert_match(/reverse later TDS-assessed bill/, error.message)
    assert_equal "posted", @bill.reload.state
  end

  test "payment clears the net AP in a plain two-way entry without deducting twice" do
    entry = pay!
    lines = entry.entry_lines.order(:line_no).map do |line|
      [ line.account_code, line.amounts.find_by!(slot_role: "transaction").amount_minor ]
    end
    assert_equal [ [ "1010", -@net_payable ], [ "2000", @net_payable ] ], lines
    assert_equal 0, Posting::Clearing.open_amount(@payable.reload)
    assert_equal 1, TdsDeduction.for_tenant(@org.tenant.id).count
  end

  test "a below-threshold bill freezes a zero assessment for later aggregate calculations" do
    bill = build_bill(reference: "NS-115", date: Date.new(2026, 8, 2), amount: "5000.00")
    assert_equal "194C", bill.tds_section
    assert_equal 4_000_000, bill.tds_prior_taxable_minor
    assert_equal 0, bill.tds_minor

    entry = Documents::Post.call(bill, actor: "u:#{@org.user.id}")
    refute entry.entry_lines.exists?(account_code: "2110")
    assert_equal 1, TdsDeduction.for_tenant(@org.tenant.id).count,
      "zero assessments affect thresholds but do not create a deduction event"
  end

  test "payment-time TDS input is rejected so tax cannot be deducted twice" do
    error = assert_raises(Settlements::InvalidSettlement) { pay!(tds_section: "194C") }
    assert_match(/assessed when the purchase bill is credited/, error.message)
  end

  test "reversal posts an explicit offset deduction and nets the return evidence" do
    Documents::Reverse.call(@bill, actor: "u:#{@org.user.id}", on: Date.new(2026, 8, 3))

    rows = TdsDeduction.for_tenant(@org.tenant.id).order(:id).to_a
    assert_equal %w[deduction reversal], rows.map(&:kind)
    assert_equal rows.first.id, rows.last.reverses_tds_deduction_id
    assert_equal(-80_000, rows.last.signed_tds_minor)

    report = Reports.tds_return_26q(@org.tenant.id, fiscal_year: 2026, quarter: 2)
    assert_equal 0, report.fetch("total_taxable_minor")
    assert_equal 0, report.fetch("total_tds_minor")
  end

  private

  def build_bill(reference:, date:, amount:, quantity: "1", tds_section: nil)
    PurchaseBills::BuildDraft.call(
      tenant: @org.tenant, party_id: @vendor.id, tax_registration_id: @registration.id,
      document_date: date, due_date: date + 30,
      place_of_supply_state_code: "27", external_reference: reference,
      place_of_supply_override_reason: "Supplier invoice identifies the Maharashtra recipient location",
      actor: @org.user,
      tds_section: tds_section,
      lines: [ { item_id: @service.id, quantity: quantity, unit_price: amount } ]
    )
  end
end
