# frozen_string_literal: true

require "test_helper"

class OpenItemReportFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "open-item-report-flow@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Open Item Report Flow"
    )
    entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    office.update!(
      address_line1: "1 Ledger Lane", city: "Mumbai", postal_code: "400001",
      state_code: "27", country_code: "IN"
    )
    registration = TaxRegistrations::Manage.create!(
      tenant: @org.tenant, entity: entity,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2026, 4, 1)
      },
      office_ids: [ office.id ], actor: @org.user
    )
    @customer = create_party("C-001", "Acme Customer", "customer", "27AAPFU0939F1ZV", "27")
    vendor = create_party("V-001", "Acme Vendor", "vendor", "29AAAAA0300L1Z8", "29")
    service = Items::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        code: "CONSULT", name: "Consulting services", item_type: "service",
        hsn_sac_code: "998311", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
        cess_rate_basis_points: 0, income_account_code: "4000", expense_account_code: "5000"
      },
      actor: @org.user
    )
    invoice = SalesInvoices::BuildDraft.call(
      tenant: @org.tenant, party_id: @customer.id, tax_registration_id: registration.id,
      document_date: Date.new(2026, 7, 31), due_date: Date.new(2026, 8, 30),
      place_of_supply_state_code: "27",
      lines: [ { item_id: service.id, quantity: "2", unit_price: "50.00" } ]
    )
    Documents::Post.call(invoice, actor: "u:#{@org.user.id}")
    bill = PurchaseBills::BuildDraft.call(
      tenant: @org.tenant, party_id: vendor.id, tax_registration_id: registration.id,
      document_date: Date.new(2026, 7, 31), due_date: Date.new(2026, 8, 30),
      place_of_supply_state_code: "27", external_reference: "V-INV-001",
      lines: [ { item_id: service.id, quantity: "2", unit_price: "50.00" } ]
    )
    Documents::Post.call(bill, actor: "u:#{@org.user.id}")
    receivable = EntryLine.joins(:entry).find_by!(
      entries: { document_id: invoice.id }, account_code: "1200"
    )
    receipt = Settlements::BuildDraft.call(
      tenant: @org.tenant, doc_type: "RC", document_date: Date.new(2026, 8, 15),
      bank_account_code: "1010",
      allocations: [
        { target_entry_line_id: receivable.id, amount: "40.00", clearing_mode: "partial" }
      ]
    )
    Documents::Post.call(receipt, actor: "u:#{@org.user.id}")
    sign_in_as(@org.user)
  end

  test "browser shows aged AR AP and a party ledger without implying historical reconstruction" do
    get aged_receivables_report_path, params: { aged_to: "2026-09-30" }
    assert_response :success
    assert_select "h1", "Aged receivables"
    assert_select ".summary-strip", text: /INR 78\.00/
    assert_select "td", text: /61 days/
    assert_select "small", text: /current-open-item view.*not a reconstructed historical snapshot/i

    get aged_payables_report_path, params: { aged_to: "2026-09-30" }
    assert_response :success
    assert_select "h1", "Aged payables"
    assert_select "tfoot", text: /INR 118\.00/
    assert_select "td", text: /Acme Vendor/

    get party_ledger_report_path, params: { party_id: @customer.id }
    assert_response :success
    assert_select "h1", "Customer and vendor ledger"
    assert_select ".summary-strip", text: /INR 78\.00/
    assert_select "tbody tr", count: 2
    assert_select "td", text: /INR 118\.00/
    assert_select "td", text: /INR 40\.00/
  end

  test "JSON reports preserve buckets and tenant boundaries" do
    get "/api/v1/reports/aged_receivables", params: { aged_to: "2026-09-30" }
    assert_response :success
    report = JSON.parse(response.body).fetch("aged_open_items")
    assert_equal 7_800, report.fetch("total_minor")
    assert_equal 7_800, report.dig("totals", "days_61_90")

    get "/api/v1/reports/party_ledger", params: { party_id: @customer.id }
    assert_response :success
    ledger = JSON.parse(response.body).fetch("party_ledger")
    assert_equal 7_800, ledger.fetch("balance_minor")
    assert_equal 2, ledger.fetch("rows").size

    other = Onboarding::SignUp.call(
      email: "open-item-report-other@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Open Item Report Other"
    )
    sign_out
    sign_in_as(other.user)
    get "/api/v1/reports/party_ledger", params: { party_id: @customer.id }
    assert_response :not_found
  end

  private

  def create_party(number, name, role, gstin, state)
    Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        party_number: number, name: name, state_code: state, country_code: "IN",
        address_line1: "2 Party Road", city: state == "27" ? "Mumbai" : "Bengaluru",
        postal_code: state == "27" ? "400002" : "560002"
      },
      roles: [ role ],
      tax_registration_attributes: {
        kind: "GSTIN", identifier: gstin, valid_from: Date.new(2026, 4, 1)
      },
      actor: @org.user
    )
  end
end
