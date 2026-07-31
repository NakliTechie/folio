# frozen_string_literal: true

require "test_helper"

class PurchaseDebitNoteTest < ActiveSupport::TestCase
  DOCUMENT_DATE = Date.new(2026, 7, 31)

  setup do
    @org = Onboarding::SignUp.call(
      email: "purchase-debit-model@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Purchase Debit Model"
    )
    entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office.update!(
      address_line1: "1 Ledger Lane", city: "Mumbai", postal_code: "400001",
      state_code: "27", country_code: "IN"
    )
    @buyer_registration = TaxRegistrations::Manage.create!(
      tenant: @org.tenant, entity: entity,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2026, 4, 1)
      },
      office_ids: [ @office.id ], actor: @org.user
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
    @bill = PurchaseBills::BuildDraft.call(
      tenant: @org.tenant, party_id: @vendor.id, tax_registration_id: @buyer_registration.id,
      document_date: DOCUMENT_DATE, due_date: DOCUMENT_DATE + 30,
      place_of_supply_state_code: "27", external_reference: "V-INV-001",
      narration: "July legal fees",
      lines: [ { item_id: @service.id, quantity: "2", unit_price: "50.00" } ]
    )
    Documents::Post.call(@bill, actor: actor)
  end

  test "supplier debit increases expense and GST and creates a separate open payable" do
    note = build_debit(quantity: "0.5")
    assert_equal 2_500, note.subtotal_minor
    assert_equal 450, note.tax_minor
    assert_equal({ "cgst" => 225, "sgst" => 225 }, note.tax_breakdown)
    assert Documents::Simulate.call(note).fetch(:balanced)

    entry = Documents::Post.call(note, actor: actor)
    assert_equal "PD/26-27/00001", note.reload.document_number
    assert_equal [ "2000", "5000", "1210", "1210" ],
      entry.entry_lines.order(:line_no).pluck(:account_code)
    assert_equal [ -2_950, 2_500, 225, 225 ], transaction_amounts(entry)

    bill_payable = payable_for(@bill)
    debit_payable = entry.entry_lines.find_by!(account_code: "2000")
    assert_equal 11_800, Posting::Clearing.open_amount(bill_payable)
    assert_equal 2_950, Posting::Clearing.open_amount(debit_payable)
    assert_nil bill_payable.cleared_on
    assert_nil debit_payable.cleared_on
    refute @bill.reload.reversible?
    refute note.reversible?
  end

  test "supplier debit rejects altered frozen values and duplicate vendor references" do
    first = build_debit(quantity: "0.5", external_reference: " supplier-dn-7 ")
    assert_equal "SUPPLIER-DN-7", first.external_reference

    error = assert_raises(PurchaseDebitNotes::InvalidDebitNote) do
      build_debit(quantity: "0.5", external_reference: "SUPPLIER-DN-7")
    end
    assert_match(/already recorded/, error.message)

    first.document_lines.first.update_column(:taxable_minor, 2_501)
    error = assert_raises(Documents::InvalidDocument) do
      Documents::Post.call(first, actor: actor)
    end
    assert_match(/value was altered/, error.message)
    assert_equal "draft", first.reload.state
  end

  test "supplier debit remains linked after a projection rebuild" do
    note = build_debit(quantity: "1")
    Documents::Post.call(note, actor: actor)
    old_entry_id = note.posted_entry_id

    Posting.rebuild!(@org.tenant.id)

    refute_equal old_entry_id, note.reload.posted_entry_id
    assert_equal @bill.id, note.debit_note_for_document_id
    assert_equal 5_900, Posting::Clearing.open_amount(payable_for(note))
  end

  test "supplier debit increases the purchase-book GST reference" do
    note = build_debit(quantity: "0.5")
    Documents::Post.call(note, actor: actor)

    report = Reports::GstReturns.call(
      tenant_id: @org.tenant.id, tax_registration_id: @buyer_registration.id,
      from_date: DOCUMENT_DATE, to_date: DOCUMENT_DATE + 1
    )
    input_tax = report.dig(:gstr_3b, :table_4_a_5_book_input_tax_reference)
    assert_equal 1, input_tax[:document_count]
    assert_equal 1, input_tax[:supplier_debit_note_count]
    assert_equal 0, input_tax[:supplier_credit_note_count]
    assert_equal 12_500, input_tax[:taxable_value_minor]
    assert_equal 14_750, input_tax[:invoice_value_minor]
    assert_equal 1_125, input_tax.dig(:tax, :cgst)
    assert_equal 1_125, input_tax.dig(:tax, :sgst)
  end

  private

  def actor = "u:#{@org.user.id}"

  def build_debit(quantity:, external_reference: "V-DN-001")
    PurchaseDebitNotes::BuildDraft.call(
      tenant: @org.tenant, purchase_bill_id: @bill.id,
      document_date: DOCUMENT_DATE + 1, external_reference: external_reference,
      reason_code: "additional_charge", narration: "Additional service charge",
      lines: [ { document_line_id: @bill.document_lines.first.id, quantity: quantity } ]
    )
  end

  def payable_for(document)
    Entry.find(document.posted_entry_id).entry_lines.find_by!(account_code: "2000")
  end

  def transaction_amounts(entry)
    entry.entry_lines.order(:line_no).map do |line|
      line.amounts.find_by!(slot_role: "transaction").amount_minor
    end
  end
end
