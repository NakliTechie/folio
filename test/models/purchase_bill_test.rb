# frozen_string_literal: true

require "test_helper"

class PurchaseBillTest < ActiveSupport::TestCase
  BILL_DATE = Date.new(2026, 7, 31)

  setup do
    @org = Onboarding::SignUp.call(
      email: "purchase-bill-model@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Purchase Bill Model"
    )
    @entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office.update!(
      address_line1: "1 Ledger Lane", city: "Mumbai", postal_code: "400001",
      state_code: "27", country_code: "IN"
    )
    @buyer_registration = TaxRegistrations::Manage.create!(
      tenant: @org.tenant,
      entity: @entity,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2026, 4, 1)
      },
      office_ids: [ @office.id ],
      actor: @org.user
    )
    @vendor = Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        party_number: "V-001", name: "Acme Vendor", state_code: "27", country_code: "IN",
        address_line1: "2 Supplier Road", city: "Mumbai", postal_code: "400002"
      },
      roles: [ "vendor" ],
      tax_registration_attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", valid_from: Date.new(2026, 4, 1)
      },
      actor: @org.user
    )
    @service = Items::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        code: "LEGAL", name: "Legal services", item_type: "service",
        hsn_sac_code: "998211", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
        cess_rate_basis_points: 0, income_account_code: "4000", expense_account_code: "5000"
      },
      actor: @org.user
    )
  end

  test "an intra-state bill freezes input GST and posts an open vendor payable" do
    bill = build_bill

    assert_equal "V-INV-001", bill.external_reference
    assert_equal 10_000, bill.subtotal_minor
    assert_equal 1_800, bill.tax_minor
    assert_equal({ "cgst" => 900, "sgst" => 900 }, bill.tax_breakdown)
    assert_equal "27AAPFU0939F1ZV", bill.party_snapshot.fetch("gstin")
    assert_equal "5000", bill.document_lines.first.item_snapshot.fetch("expenseAccountCode")
    assert Documents::Simulate.call(bill).fetch(:balanced)

    entry = Documents::Post.call(bill, actor: "u:#{@org.user.id}")
    assert_equal "PB/26-27/00001", bill.reload.document_number
    assert_operator bill.document_number.length, :<=, 16
    assert_equal [ "2000", "5000", "1210", "1210" ], entry.entry_lines.order(:line_no).pluck(:account_code)

    payable = entry.entry_lines.find_by!(account_code: "2000")
    assert payable.open_item?
    assert_equal "vendor", payable.party_role
    assert_equal @vendor.id, payable.party_id
    assert_equal(-11_800, payable.amounts.find_by!(slot_role: "transaction").amount_minor)

    expense = entry.entry_lines.find_by!(account_code: "5000")
    assert_equal 10_000, expense.amounts.find_by!(slot_role: "transaction").amount_minor
    input_tax = entry.entry_lines.where(account_code: "1210").order(:tax_component)
    assert_equal %w[cgst sgst], input_tax.pluck(:tax_component)
    assert_equal [ 900, 900 ], input_tax.map { |line| line.amounts.find_by!(slot_role: "transaction").amount_minor }

    payload = JSON.parse(LedgerEvent.find(entry.ledger_event_id).payload)
    payable_payload = payload.fetch("lines").find { |line| line["accountCode"] == "2000" }
    assert_equal "V-INV-001", payable_payload.dig("extra", "supplierInvoiceNumber")
  end

  test "an inter-state bill posts IGST to the input-credit account" do
    bill = build_bill(place_of_supply_state_code: "29")
    assert_equal({ "igst" => 1_800 }, bill.tax_breakdown)

    entry = Documents::Post.call(bill, actor: "u:#{@org.user.id}")
    tax_line = entry.entry_lines.find_by!(account_code: "1210")
    assert_equal "igst", tax_line.tax_component
    assert_equal 1_800, tax_line.amounts.find_by!(slot_role: "transaction").amount_minor
  end

  test "supplier invoice references are case-insensitively unique per vendor" do
    build_bill(external_reference: " vendor-ref-7 ")

    error = assert_raises(PurchaseBills::InvalidBill) do
      build_bill(external_reference: "VENDOR-REF-7")
    end
    assert_match(/already recorded/, error.message)
    assert_equal 1, Document.where(tenant_id: @org.tenant.id, doc_type: "PB").count

    other_vendor = Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        party_number: "V-002", name: "Second Vendor", state_code: "29", country_code: "IN",
        address_line1: "3 Supplier Road", city: "Bengaluru", postal_code: "560003"
      },
      roles: [ "vendor" ],
      tax_registration_attributes: {
        kind: "GSTIN", identifier: "29AAAAA0300L1Z8", valid_from: Date.new(2026, 4, 1)
      },
      actor: @org.user
    )
    bill = build_bill(party_id: other_vendor.id, external_reference: "vendor-ref-7")
    assert_equal "VENDOR-REF-7", bill.external_reference
  end

  test "posting rejects altered frozen tax before allocating a number" do
    bill = build_bill
    bill.document_lines.first.update_column(:tax_components, { "cgst" => 800, "sgst" => 900 })

    error = assert_raises(Documents::InvalidDocument) do
      Documents::Post.call(bill, actor: "u:#{@org.user.id}")
    end
    assert_match(/tax was altered/, error.message)
    assert_nil NumberRange.find_by(tenant_id: @org.tenant.id, doc_type: "PB")
    assert_equal "draft", bill.reload.state
  end

  test "an unsettled bill reverses from frozen snapshots and clears its payable" do
    bill = build_bill
    Documents::Post.call(bill, actor: "u:#{@org.user.id}")
    Parties::Manage.update!(
      party: @vendor, attributes: { active: false }, roles: @vendor.role_codes, actor: @org.user
    )
    Items::Manage.update!(item: @service, attributes: { active: false }, actor: @org.user)
    TaxRegistrations::Manage.update!(
      registration: @buyer_registration, attributes: { active: false },
      office_ids: [ @office.id ], actor: @org.user
    )

    reversal_entry = Documents::Reverse.call(bill, actor: "u:#{@org.user.id}")
    assert_equal "reversed", bill.reload.state
    assert reversal_entry.entry_lines.all?(&:is_negative_posting)
    amounts = reversal_entry.entry_lines.order(:line_no).map do |line|
      line.amounts.find_by!(slot_role: "transaction").amount_minor
    end
    assert_equal [ 11_800, -10_000, -900, -900 ], amounts

    payable = Entry.find(bill.posted_entry_id).entry_lines.find_by!(account_code: "2000")
    assert_equal 11_800, payable.cleared_amount_minor
    assert_equal reversal_entry.id, payable.cleared_by_entry_id
  end

  test "a fully settled bill cannot reverse into hidden payables" do
    bill = build_bill
    entry = Documents::Post.call(bill, actor: "u:#{@org.user.id}")
    payable = entry.entry_lines.find_by!(account_code: "2000")
    Posting::Clearing.clear!(
      item: payable, amount_minor: 11_800, cleared_on: BILL_DATE,
      mode: :full, actor: "u:#{@org.user.id}"
    )

    refute bill.reload.reversible?
    assert_raises(Documents::Reverse::NotReversible) do
      Documents::Reverse.call(bill, actor: "u:#{@org.user.id}")
    end
    assert_equal "posted", bill.reload.state
  end

  test "bills require a registered vendor and a supplier invoice number" do
    error = assert_raises(PurchaseBills::InvalidBill) { build_bill(external_reference: "") }
    assert_match(/supplier invoice number is required/, error.message)

    @vendor.party_roles.find_by!(role: "vendor").update!(role: "customer")
    error = assert_raises(PurchaseBills::InvalidBill) { build_bill }
    assert_match(/not a vendor/, error.message)
  end

  test "the purchase-bill vertical fails closed outside an India INR profile" do
    other = Onboarding::SignUp.call(
      email: "purchase-bill-us@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Purchase Bill US",
      jurisdiction_profile: "US",
      functional_currency: "USD",
      fiscal_year_variant: "CAL"
    )

    error = assert_raises(PurchaseBills::InvalidBill) do
      PurchaseBills::BuildDraft.call(
        tenant: other.tenant, party_id: 0, tax_registration_id: 0,
        document_date: BILL_DATE, due_date: BILL_DATE,
        place_of_supply_state_code: "27", external_reference: "X", lines: []
      )
    end
    assert_match(/India\/INR/, error.message)
  end

  private

  def build_bill(party_id: @vendor.id, place_of_supply_state_code: "27", external_reference: "V-INV-001")
    PurchaseBills::BuildDraft.call(
      tenant: @org.tenant,
      party_id: party_id,
      tax_registration_id: @buyer_registration.id,
      document_date: BILL_DATE,
      due_date: BILL_DATE + 30,
      place_of_supply_state_code: place_of_supply_state_code,
      external_reference: external_reference,
      narration: "July legal fees",
      lines: [ { item_id: @service.id, quantity: "2", unit_price: "50.00" } ]
    )
  end
end
