# frozen_string_literal: true

require "test_helper"

class CreditNoteTest < ActiveSupport::TestCase
  DOCUMENT_DATE = Date.new(2026, 7, 31)

  setup do
    @org = Onboarding::SignUp.call(
      email: "credit-note-model@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Credit Note Model"
    )
    @entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office.update!(
      address_line1: "1 Ledger Lane", city: "Mumbai", postal_code: "400001",
      state_code: "27", country_code: "IN"
    )
    @seller_registration = TaxRegistrations::Manage.create!(
      tenant: @org.tenant,
      entity: @entity,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2026, 4, 1)
      },
      office_ids: [ @office.id ], actor: @org.user
    )
    @customer = Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        party_number: "C-001", name: "Acme Customer", state_code: "27", country_code: "IN",
        address_line1: "2 Customer Road", city: "Mumbai", postal_code: "400002"
      },
      roles: [ "customer" ],
      tax_registration_attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", valid_from: Date.new(2026, 4, 1)
      },
      actor: @org.user
    )
    @service = Items::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        code: "CONSULT", name: "Consulting services", item_type: "service",
        hsn_sac_code: "998311", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
        cess_rate_basis_points: 0, income_account_code: "4000", expense_account_code: "5000"
      },
      actor: @org.user
    )
    @invoice = SalesInvoices::BuildDraft.call(
      tenant: @org.tenant,
      party_id: @customer.id,
      tax_registration_id: @seller_registration.id,
      document_date: DOCUMENT_DATE,
      due_date: DOCUMENT_DATE + 30,
      place_of_supply_state_code: "27",
      lines: [ { item_id: @service.id, quantity: "2", unit_price: "50.00" } ]
    )
    Documents::Post.call(@invoice, actor: "u:#{@org.user.id}")
  end

  test "partial credit note reverses revenue and GST and applies both receivable sides" do
    note = build_credit_note(quantity: "0.5")
    assert_equal 2_500, note.subtotal_minor
    assert_equal 450, note.tax_minor
    assert_equal({ "cgst" => 225, "sgst" => 225 }, note.tax_breakdown)
    assert Documents::Simulate.call(note)[:balanced]

    entry = Documents::Post.call(note, actor: "u:#{@org.user.id}")
    assert_equal "CN/26-27/00001", note.reload.document_number
    assert_equal [ "1200", "4000", "2100", "2100" ], entry.entry_lines.order(:line_no).pluck(:account_code)
    amounts = entry.entry_lines.order(:line_no).map do |line|
      line.amounts.find_by!(slot_role: "transaction").amount_minor
    end
    assert_equal [ -2_950, 2_500, 225, 225 ], amounts

    invoice_receivable = receivable_for(@invoice)
    credit_receivable = entry.entry_lines.find_by!(account_code: "1200")
    assert_equal 2_950, invoice_receivable.reload.cleared_amount_minor
    assert_nil invoice_receivable.cleared_on
    assert_equal 8_850, Posting::Clearing.open_amount(invoice_receivable)
    assert_equal 2_950, credit_receivable.reload.cleared_amount_minor
    assert_equal DOCUMENT_DATE + 1, credit_receivable.cleared_on
    assert_equal 1.5.to_d, CreditNotes::BuildDraft.remaining_quantity(@invoice.document_lines.first)
    refute @invoice.reload.reversible?
    refute note.reversible?
  end

  test "a credit after settlement leaves the excess as an open customer credit" do
    invoice_receivable = receivable_for(@invoice)
    Posting::Clearing.clear!(
      item: invoice_receivable, amount_minor: 10_000, cleared_on: DOCUMENT_DATE,
      mode: :partial, actor: "u:#{@org.user.id}"
    )

    note = build_credit_note(quantity: "2")
    entry = Documents::Post.call(note, actor: "u:#{@org.user.id}")
    credit_receivable = entry.entry_lines.find_by!(account_code: "1200")

    assert_equal 11_800, invoice_receivable.reload.cleared_amount_minor
    assert_equal 1_800, credit_receivable.reload.cleared_amount_minor
    assert_nil credit_receivable.cleared_on
    assert_equal 10_000, Posting::Clearing.open_amount(credit_receivable)
  end

  test "cumulative credit quantities cannot exceed the source invoice" do
    first = build_credit_note(quantity: "1")
    Documents::Post.call(first, actor: "u:#{@org.user.id}")

    error = assert_raises(CreditNotes::InvalidCreditNote) do
      build_credit_note(quantity: "1.000001")
    end
    assert_match(/no more than 1\.0/, error.message)

    second = build_credit_note(quantity: "1")
    second.document_lines.first.update_column(:quantity, 1.5)
    error = assert_raises(Documents::InvalidDocument) do
      Documents::Post.call(second, actor: "u:#{@org.user.id}")
    end
    assert_match(/exceeds the uncredited quantity/, error.message)
    assert_equal "draft", second.reload.state
    assert_equal 2, NumberRange.find_by!(tenant_id: @org.tenant.id, doc_type: "CN").next_value
  end

  test "credit note uses invoice snapshots after mutable masters are deactivated" do
    Parties::Manage.update!(
      party: @customer, attributes: { active: false }, roles: @customer.role_codes, actor: @org.user
    )
    Items::Manage.update!(item: @service, attributes: { active: false }, actor: @org.user)
    TaxRegistrations::Manage.update!(
      registration: @seller_registration, attributes: { active: false },
      office_ids: [ @office.id ], actor: @org.user
    )

    note = build_credit_note(quantity: "1")
    Documents::Post.call(note, actor: "u:#{@org.user.id}")
    assert_equal @invoice.party_snapshot, note.party_snapshot
    assert_equal @invoice.document_lines.first.item_snapshot, note.document_lines.first.item_snapshot
  end

  test "the final partial note absorbs rounding so cumulative credits exactly match the invoice" do
    tiny_invoice = SalesInvoices::BuildDraft.call(
      tenant: @org.tenant,
      party_id: @customer.id,
      tax_registration_id: @seller_registration.id,
      document_date: DOCUMENT_DATE,
      due_date: DOCUMENT_DATE + 30,
      place_of_supply_state_code: "29",
      lines: [ { item_id: @service.id, quantity: "3", unit_price: "0.01" } ]
    )
    Documents::Post.call(tiny_invoice, actor: "u:#{@org.user.id}")

    notes = 3.times.map do |index|
      note = CreditNotes::BuildDraft.call(
        tenant: @org.tenant,
        invoice_id: tiny_invoice.id,
        document_date: DOCUMENT_DATE + index + 1,
        reason_code: "value_reduction",
        lines: [ { document_line_id: tiny_invoice.document_lines.first.id, quantity: "1" } ]
      )
      Documents::Post.call(note, actor: "u:#{@org.user.id}")
      note
    end

    assert_equal tiny_invoice.subtotal_minor, notes.sum(&:subtotal_minor)
    assert_equal tiny_invoice.tax_minor, notes.sum(&:tax_minor)
    assert_equal tiny_invoice.total_minor, notes.sum(&:total_minor)
    assert_equal 0.to_d, CreditNotes::BuildDraft.remaining_quantity(tiny_invoice.document_lines.first)
  end

  test "credit notes require a same-tenant posted source and cannot be reversed" do
    draft_invoice = SalesInvoices::BuildDraft.call(
      tenant: @org.tenant,
      party_id: @customer.id,
      tax_registration_id: @seller_registration.id,
      document_date: DOCUMENT_DATE,
      due_date: DOCUMENT_DATE + 30,
      place_of_supply_state_code: "27",
      lines: [ { item_id: @service.id, quantity: "1", unit_price: "10.00" } ]
    )
    error = assert_raises(CreditNotes::InvalidCreditNote) do
      CreditNotes::BuildDraft.call(
        tenant: @org.tenant,
        invoice_id: draft_invoice.id,
        document_date: DOCUMENT_DATE + 1,
        reason_code: "value_reduction",
        lines: [ { document_line_id: draft_invoice.document_lines.first.id, quantity: "1" } ]
      )
    end
    assert_match(/source invoice/, error.message)

    note = build_credit_note(quantity: "1")
    Documents::Post.call(note, actor: "u:#{@org.user.id}")
    assert_raises(Documents::Reverse::NotReversible) do
      Documents::Reverse.call(note, actor: "u:#{@org.user.id}")
    end
  end

  private

  def build_credit_note(quantity:)
    CreditNotes::BuildDraft.call(
      tenant: @org.tenant,
      invoice_id: @invoice.id,
      document_date: DOCUMENT_DATE + 1,
      reason_code: "service_deficiency",
      narration: "Service-level adjustment",
      lines: [ { document_line_id: @invoice.document_lines.first.id, quantity: quantity } ]
    )
  end

  def receivable_for(document)
    Entry.find(document.posted_entry_id).entry_lines.find_by!(account_code: "1200")
  end
end
