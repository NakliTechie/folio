# frozen_string_literal: true

require "test_helper"

class OpenItemCreditTest < ActiveSupport::TestCase
  DATE = Date.new(2026, 8, 1)

  setup do
    @org = Onboarding::SignUp.call(
      email: "open-credit@folio.invalid", password: "correct-horse-battery",
      org_name: "Open Credit Books"
    )
    @entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @ledger = Ledger.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @customer = Party.create!(
      tenant_id: @org.tenant.id, party_number: "C-NET", name: "Netting Customer"
    )
    @vendor = Party.create!(
      tenant_id: @org.tenant.id, party_number: "V-NET", name: "Netting Vendor"
    )
  end

  test "opposite customer items are reported distinctly and governedly netted" do
    charge = post_open_item(role: "customer", party: @customer, amount: 10_000, assignment: "SI/1")
    credit = post_open_item(role: "customer", party: @customer, amount: -6_000, assignment: "CN/1")

    before = Reports.aged_open_items(@org.tenant.id, role: "customer", aged_to: DATE)
    assert_equal [ charge.id ], before[:rows].pluck(:entry_line_id)
    assert_equal [ credit.id ], before[:credits].pluck(:entry_line_id)
    assert_equal 10_000, before[:total_minor]
    assert_equal 6_000, before[:credit_total_minor]
    assert_equal 4_000, before[:net_total_minor]

    result = OpenItemCredits::Net.call(
      tenant: @org.tenant, credit_entry_line_id: credit.id, target_entry_line_id: charge.id,
      amount_minor: 6_000, applied_on: DATE, actor: "u:#{@org.user.id}"
    )
    assert_match(/\A[0-9a-f-]{36}\z/, result.reference)
    assert_equal 4_000, Posting::Clearing.open_amount(charge.reload)
    assert_equal DATE, credit.reload.cleared_on

    references = [ result.credit_event, result.target_event ].map do |event|
      JSON.parse(event.payload).dig("clearing", "reference")
    end
    assert_equal references.first, references.last
    assert_equal "open_item_netting", references.first.fetch("kind")
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]

    Posting.rebuild!(@org.tenant.id)
    rebuilt = Reports.aged_open_items(@org.tenant.id, role: "customer", aged_to: DATE)
    assert_equal 4_000, rebuilt[:total_minor]
    assert_equal 0, rebuilt[:credit_total_minor]
  end

  test "customer and vendor credits can be refunded with the correct cash direction" do
    customer_credit = post_open_item(
      role: "customer", party: @customer, amount: -5_000, assignment: "CN/2"
    )
    customer_refund = post_refund(customer_credit, amount: 3_000)
    assert_equal "RF", customer_refund.doc_type
    assert_equal [ -3_000, 3_000 ], transaction_amounts(customer_refund)
    assert_equal 2_000, Posting::Clearing.open_amount(customer_credit.reload)

    vendor_credit = post_open_item(
      role: "vendor", party: @vendor, amount: 4_000, assignment: "PC/2"
    )
    vendor_refund = post_refund(vendor_credit, amount: 4_000)
    assert_equal [ 4_000, -4_000 ], transaction_amounts(vendor_refund)
    assert_equal DATE, vendor_credit.reload.cleared_on
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]
  end

  private

  def post_refund(credit, amount:)
    document = OpenItemCredits::BuildRefund.call(
      tenant: @org.tenant, credit_entry_line_id: credit.id, amount_minor: amount,
      bank_account_code: "1010", document_date: DATE, narration: "Credit refund"
    )
    Documents::Post.call(
      document, actor: "u:#{@org.user.id}", authorize: { user: @org.user },
      required_capability: "payments.create"
    )
    document.reload
  end

  def transaction_amounts(document)
    Entry.find(document.posted_entry_id).entry_lines.order(:line_no).map do |line|
      line.amounts.find_by!(slot_role: "transaction").amount_minor
    end
  end

  def post_open_item(role:, party:, amount:, assignment:)
    account_code = role == "customer" ? "1200" : "2000"
    entry = Posting::PostEntry.post!(
      tenant_id: @org.tenant.id, actor: "test", origin: "test",
      document_date: DATE, posting_date: DATE, entered_at: Time.utc(2026, 8, 1),
      fiscal_year: 2026, period_no: 5,
      lines: [
        { line_no: 1, account_code: account_code, ledger_id: @ledger.id,
          entity_id: @entity.id, office_id: @office.id, party_id: party.id,
          party_role: role, open_item: true, item_class: "normal",
          assignment: assignment, baseline_date: DATE, due_date: DATE,
          amounts: [ { slot_role: "transaction", currency: "INR",
                       minor_unit_exponent: 2, amount_minor: amount } ] },
        { line_no: 2, account_code: "1000", ledger_id: @ledger.id,
          entity_id: @entity.id, office_id: @office.id,
          amounts: [ { slot_role: "transaction", currency: "INR",
                       minor_unit_exponent: 2, amount_minor: -amount } ] }
      ]
    )
    entry.entry_lines.find_by!(line_no: 1)
  end
end
