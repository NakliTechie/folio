# frozen_string_literal: true

require "test_helper"

class PurchaseCreditNoteTest < ActiveSupport::TestCase
  DOCUMENT_DATE = Date.new(2026, 7, 31)

  setup do
    @org = Onboarding::SignUp.call(
      email: "purchase-credit-model@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Purchase Credit Model"
    )
    entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office.update!(
      address_line1: "1 Ledger Lane", city: "Mumbai", postal_code: "400001",
      state_code: "27", country_code: "IN"
    )
    @buyer_registration = TaxRegistrations::Manage.create!(
      tenant: @org.tenant,
      entity: entity,
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
    @bill = build_bill
    Documents::Post.call(@bill, actor: actor)
  end

  test "partial supplier credit reduces expense and GST and applies both payable sides" do
    note = build_credit(quantity: "0.5")
    assert_equal 2_500, note.subtotal_minor
    assert_equal 450, note.tax_minor
    assert_equal({ "cgst" => 225, "sgst" => 225 }, note.tax_breakdown)
    assert Documents::Simulate.call(note).fetch(:balanced)

    entry = Documents::Post.call(note, actor: actor)
    assert_equal "PC/26-27/00001", note.reload.document_number
    assert_equal "V-CN-001", note.external_reference
    assert_equal [ "2000", "5000", "1210", "1210" ],
      entry.entry_lines.order(:line_no).pluck(:account_code)
    assert_equal [ 2_950, -2_500, -225, -225 ], transaction_amounts(entry)

    bill_payable = payable_for(@bill)
    credit_payable = entry.entry_lines.find_by!(account_code: "2000")
    assert_equal 2_950, bill_payable.reload.cleared_amount_minor
    assert_nil bill_payable.cleared_on
    assert_equal 8_850, Posting::Clearing.open_amount(bill_payable)
    assert_equal 2_950, credit_payable.reload.cleared_amount_minor
    assert_equal DOCUMENT_DATE + 1, credit_payable.cleared_on
    assert_equal 1.5.to_d, PurchaseCreditNotes::BuildDraft.remaining_quantity(@bill.document_lines.first)
    refute @bill.reload.reversible?
    refute note.reversible?
  end

  test "a supplier credit after payment leaves the excess as an open vendor credit" do
    bill_payable = payable_for(@bill)
    Posting::Clearing.clear!(
      item: bill_payable, amount_minor: 10_000, cleared_on: DOCUMENT_DATE,
      mode: :partial, actor: actor
    )

    note = build_credit(quantity: "2")
    entry = Documents::Post.call(note, actor: actor)
    credit_payable = entry.entry_lines.find_by!(account_code: "2000")

    assert_equal 11_800, bill_payable.reload.cleared_amount_minor
    assert_equal 1_800, credit_payable.reload.cleared_amount_minor
    assert_nil credit_payable.cleared_on
    assert_equal 10_000, Posting::Clearing.open_amount(credit_payable)
  end

  test "cumulative supplier credits cannot exceed the purchase bill" do
    first = build_credit(quantity: "1")
    Documents::Post.call(first, actor: actor)

    error = assert_raises(PurchaseCreditNotes::InvalidCreditNote) do
      build_credit(quantity: "1.000001", external_reference: "V-CN-002")
    end
    assert_match(/no more than 1\.0/, error.message)

    second = build_credit(quantity: "1", external_reference: "V-CN-003")
    second.document_lines.first.update_column(:quantity, 1.5)
    error = assert_raises(Documents::InvalidDocument) do
      Documents::Post.call(second, actor: actor)
    end
    assert_match(/exceeds the uncredited quantity/, error.message)
    assert_equal "draft", second.reload.state
    assert_equal 2, NumberRange.find_by!(tenant_id: @org.tenant.id, doc_type: "PC").next_value
  end

  test "supplier credit references are case-insensitively unique per vendor" do
    first = build_credit(quantity: "0.5", external_reference: " supplier-cn-7 ")
    assert_equal "SUPPLIER-CN-7", first.external_reference

    error = assert_raises(PurchaseCreditNotes::InvalidCreditNote) do
      build_credit(quantity: "0.5", external_reference: "SUPPLIER-CN-7")
    end
    assert_match(/already recorded/, error.message)
  end

  test "supplier credit uses purchase-bill snapshots after masters are deactivated" do
    Parties::Manage.update!(
      party: @vendor, attributes: { active: false }, roles: @vendor.role_codes, actor: @org.user
    )
    Items::Manage.update!(item: @service, attributes: { active: false }, actor: @org.user)
    TaxRegistrations::Manage.update!(
      registration: @buyer_registration, attributes: { active: false },
      office_ids: [ @office.id ], actor: @org.user
    )

    note = build_credit(quantity: "1")
    Documents::Post.call(note, actor: actor)
    assert_equal @bill.party_snapshot, note.party_snapshot
    assert_equal @bill.document_lines.first.item_snapshot, note.document_lines.first.item_snapshot
  end

  test "the final partial supplier credit absorbs rounding exactly" do
    tiny_bill = build_bill(quantity: "3", unit_price: "0.01", external_reference: "V-TINY-1")
    Documents::Post.call(tiny_bill, actor: actor)

    notes = 3.times.map do |index|
      note = PurchaseCreditNotes::BuildDraft.call(
        tenant: @org.tenant, purchase_bill_id: tiny_bill.id,
        document_date: DOCUMENT_DATE + index + 1,
        external_reference: "V-TINY-CN-#{index + 1}", reason_code: "value_reduction",
        lines: [ { document_line_id: tiny_bill.document_lines.first.id, quantity: "1" } ]
      )
      Documents::Post.call(note, actor: actor)
      note
    end

    assert_equal tiny_bill.subtotal_minor, notes.sum(&:subtotal_minor)
    assert_equal tiny_bill.tax_minor, notes.sum(&:tax_minor)
    assert_equal tiny_bill.total_minor, notes.sum(&:total_minor)
    assert_equal 0.to_d, PurchaseCreditNotes::BuildDraft.remaining_quantity(tiny_bill.document_lines.first)
  end

  test "supplier credits require a posted same-tenant source and cannot be reversed" do
    draft_bill = build_bill(external_reference: "V-DRAFT-1")
    error = assert_raises(PurchaseCreditNotes::InvalidCreditNote) do
      PurchaseCreditNotes::BuildDraft.call(
        tenant: @org.tenant, purchase_bill_id: draft_bill.id,
        document_date: DOCUMENT_DATE + 1, external_reference: "V-CN-DRAFT",
        reason_code: "value_reduction",
        lines: [ { document_line_id: draft_bill.document_lines.first.id, quantity: "1" } ]
      )
    end
    assert_match(/source bill/, error.message)

    note = build_credit(quantity: "1")
    Documents::Post.call(note, actor: actor)
    assert_raises(Documents::Reverse::NotReversible) do
      Documents::Reverse.call(note, actor: actor)
    end
  end

  private

  def actor = "u:#{@org.user.id}"

  def build_bill(quantity: "2", unit_price: "50.00", external_reference: "V-INV-001")
    PurchaseBills::BuildDraft.call(
      tenant: @org.tenant, party_id: @vendor.id, tax_registration_id: @buyer_registration.id,
      document_date: DOCUMENT_DATE, due_date: DOCUMENT_DATE + 30,
      place_of_supply_state_code: "27", external_reference: external_reference,
      narration: "July legal fees",
      lines: [ { item_id: @service.id, quantity: quantity, unit_price: unit_price } ]
    )
  end

  def build_credit(quantity:, external_reference: "V-CN-001")
    PurchaseCreditNotes::BuildDraft.call(
      tenant: @org.tenant, purchase_bill_id: @bill.id,
      document_date: DOCUMENT_DATE + 1, external_reference: external_reference,
      reason_code: "service_deficiency", narration: "Service-level adjustment",
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
