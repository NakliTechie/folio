# frozen_string_literal: true

require "test_helper"

class OpenItemCreditFlowsTest < ActionDispatch::IntegrationTest
  DATE = Date.new(2026, 8, 1)

  setup do
    @org = Onboarding::SignUp.call(
      email: "open-credit-flow@folio.invalid", password: "correct-horse-battery",
      org_name: "Open Credit Flow"
    )
    @entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @ledger = Ledger.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @customer = Party.create!(
      tenant_id: @org.tenant.id, party_number: "C-FLOW", name: "Flow Customer"
    )
    sign_in_as(@org.user)
  end

  test "owner applies a customer credit from the aged-receivables browser flow" do
    charge = post_open_item(amount: 10_000, assignment: "SI/FLOW")
    credit = post_open_item(amount: -6_000, assignment: "CN/FLOW")
    report = Reports.aged_open_items(@org.tenant.id, role: "customer", aged_to: DATE)
    assert_equal [ charge.id ], report[:rows].pluck(:entry_line_id)
    assert_equal [ credit.id ], report[:credits].pluck(:entry_line_id)
    assert Authorization.permits?(
      user: @org.user, tenant_id: @org.tenant.id, capability: "payments.create"
    )

    get aged_receivables_report_path(aged_to: DATE.iso8601)
    assert_response :success
    assert_select "h2", "Credits available to apply or refund"
    assert_select "input[type=submit][value='Apply credit']", count: 1
    assert_select "input[type=submit][value='Refund credit']", count: 1

    post net_open_item_credit_path, params: {
      open_item_credit: {
        role: "customer", credit_entry_line_id: credit.id,
        target_entry_line_id: charge.id, amount: "60.00", applied_on: DATE.iso8601
      }
    }
    assert_redirected_to aged_receivables_report_path(tenant_id: @org.tenant.id)
    assert_equal DATE, credit.reload.cleared_on
    assert_equal 4_000, Posting::Clearing.open_amount(charge.reload)

    follow_redirect!
    assert_select "[role=status]", text: /INR 60\.00 credit applied/
  end

  test "owner refunds a customer credit through the API" do
    credit = post_open_item(amount: -5_000, assignment: "CN/API")

    post "/api/v1/open_item_credits/refund", params: {
      credit_entry_line_id: credit.id, amount: "30.00", bank_account_code: "1010",
      document_date: DATE.iso8601, narration: "API credit refund"
    }
    assert_response :created
    body = JSON.parse(response.body).fetch("refund")
    assert_equal "RF/1", body.fetch("document_number")
    assert_equal 3_000, body.fetch("amount_minor")
    assert_equal 2_000, Posting::Clearing.open_amount(credit.reload)
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]
  end

  private

  def post_open_item(amount:, assignment:)
    entry = Posting::PostEntry.post!(
      tenant_id: @org.tenant.id, actor: "test", origin: "test",
      document_date: DATE, posting_date: DATE, entered_at: Time.utc(2026, 8, 1),
      fiscal_year: 2026, period_no: 5,
      lines: [
        {
          line_no: 1, account_code: "1200", ledger_id: @ledger.id,
          entity_id: @entity.id, office_id: @office.id, party_id: @customer.id,
          party_role: "customer", open_item: true, item_class: "normal",
          assignment: assignment, baseline_date: DATE, due_date: DATE,
          amounts: [
            { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2,
              amount_minor: amount }
          ]
        },
        {
          line_no: 2, account_code: "1000", ledger_id: @ledger.id,
          entity_id: @entity.id, office_id: @office.id,
          amounts: [
            { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2,
              amount_minor: -amount }
          ]
        }
      ]
    )
    entry.entry_lines.find_by!(line_no: 1)
  end
end
