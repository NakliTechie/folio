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
    @registration = TaxRegistrations::Manage.create!(
      tenant: @org.tenant, entity: entity,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2026, 4, 1)
      },
      office_ids: [ office.id ], actor: @org.user
    )
    @customer = create_party("C-001", "Acme Customer", "customer", "27AAPFU0939F1ZV", "27")
    @vendor = create_party("V-001", "Acme Vendor", "vendor", "29AAAAA0300L1Z8", "29")
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
      tenant: @org.tenant, party_id: @customer.id, tax_registration_id: @registration.id,
      document_date: Date.new(2026, 7, 31), due_date: Date.new(2026, 8, 30),
      place_of_supply_state_code: "27",
      lines: [ { item_id: @service.id, quantity: "2", unit_price: "50.00" } ]
    )
    Documents::Post.call(@invoice, actor: "u:#{@org.user.id}")
    @bill = PurchaseBills::BuildDraft.call(
      tenant: @org.tenant, party_id: @vendor.id, tax_registration_id: @registration.id,
      document_date: Date.new(2026, 7, 31), due_date: Date.new(2026, 8, 30),
      place_of_supply_state_code: "27", external_reference: "V-INV-001",
      place_of_supply_override_reason: "Supplier invoice identifies the Maharashtra recipient location",
      actor: @org.user,
      lines: [ { item_id: @service.id, quantity: "2", unit_price: "50.00" } ]
    )
    Documents::Post.call(@bill, actor: "u:#{@org.user.id}")
    receivable = EntryLine.joins(:entry).find_by!(
      entries: { document_id: @invoice.id }, account_code: "1200"
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

  test "browser and API expose a balanced day book and registration-scoped GST preparation" do
    get day_book_report_path, params: { from: "2026-07-01", to: "2026-08-31" }
    assert_response :success
    assert_select "h1", "Day book"
    assert_select ".summary-strip", text: /3.*INR 276\.00.*INR 276\.00/m
    assert_select "tbody tr", count: 3

    get "/api/v1/reports/day_book", params: { from: "2026-07-01", to: "2026-08-31" }
    assert_response :success
    day_book = JSON.parse(response.body).fetch("day_book")
    assert_equal 3, day_book.fetch("rows").size
    assert_equal day_book.fetch("debit_minor"), day_book.fetch("credit_minor")

    get gst_summary_report_path, params: {
      tax_registration_id: @registration.id, from: "2026-07-01", to: "2026-07-31"
    }
    assert_response :success
    assert_select "h1", "GSTR-1 and GSTR-3B preparation"
    assert_select "h2", text: /Table 4A/
    assert_select "th", text: /3\.1\(a\) Outward taxable supplies/
    assert_select ".table-note", text: /Reconcile.*GSTR-2B.*before filing/i

    get "/api/v1/reports/gst_summary", params: {
      tax_registration_id: @registration.id, from: "2026-07-01", to: "2026-07-31"
    }
    assert_response :success
    summary = JSON.parse(response.body).fetch("gst_summary")
    assert_equal 10_000, summary.dig("gstr_1", "table_4a_b2b_regular", "totals", "taxable_value_minor")
    assert_equal 900, summary.dig("gstr_3b", "table_3_1_a_outward_taxable", "tax", "cgst")
    assert_equal 1_800,
      summary.dig("gstr_3b", "table_4_a_5_book_input_tax_reference", "tax", "igst")
    assert_equal "requires_gstr_2b_and_eligibility_review", summary.dig("gstr_3b", "input_tax_status")
  end

  test "browser downloads current GSTR-1 Save JSON with a deterministic filing cross-check" do
    get gstr1_filing_report_path, params: {
      tax_registration_id: @registration.id, from: "2026-07-01", to: "2026-07-31"
    }
    assert_response :success
    assert_equal "application/json", response.media_type
    assert_match(/gstr1-072026-27AAPFU0939F1ZV\.json/, response.headers.fetch("Content-Disposition"))
    payload = JSON.parse(response.body)
    assert_equal "072026", payload.fetch("fp")
    assert_equal @invoice.document_number, payload.dig("b2b", 0, "inv", 0, "inum")
    assert_equal 100, payload.dig("b2b", 0, "inv", 0, "itms", 0, "itm_det", "txval")
    assert_equal "998311", payload.dig("hsn", "hsn_b2b", 0, "hsn_sc")

    post "/api/v1/reports/gst_filing", params: {
      form: "GSTR-1", tax_registration_id: @registration.id,
      from: "2026-07-01", to: "2026-07-31"
    }
    assert_response :success
    filing = JSON.parse(response.body).fetch("gst_filing")
    assert_equal "v5.0", filing.fetch("schema_version")
    assert_equal "FINAL", filing.fetch("schema_status")
    assert_equal "matched", filing.dig("crosscheck", "status")
    assert_equal 10_000, filing.dig("crosscheck", "taxable_value_minor")
    assert_match(/\A[0-9a-f]{64}\z/, filing.fetch("payload_sha256"))
  end

  test "authorized browser and API users can prepare and download Form 26Q and Form 16A" do
    TdsDeduction.create!(
      tenant_id: @org.tenant.id, party_id: @vendor.id, section: "194C",
      statutory_reference: "Income-tax Act 2025 §393(1), Table Sl. 6(i)",
      rate_basis_points: 200, gross_minor: 118_000, gst_minor: 18_000,
      taxable_minor: 100_000, deductible_base_minor: 100_000, tds_minor: 2_000,
      base_basis: "invoice_excluding_separately_stated_gst", trigger_event: "credit",
      kind: "deduction", deduction_date: Date.new(2026, 7, 31),
      deductee_pan: "AAAAA0300L", deductee_name_snapshot: @vendor.name,
      source_document_id: @bill.id, fiscal_year: 2026, quarter: 2
    )

    get tds_report_path, params: { fiscal_year: 2026, quarter: 2, party_id: @vendor.id }
    assert_response :success
    assert_select "h1", "Form 26Q and Form 16A"
    assert_select ".summary-strip", text: /INR 20\.00/
    assert_select "h2", text: @vendor.name

    get tds_form_26q_report_path, params: { fiscal_year: 2026, quarter: 2 }
    assert_response :success
    assert_equal "application/json", response.media_type
    assert_match(/form-26q-fy2026-q2\.json/, response.headers.fetch("Content-Disposition"))
    assert_equal 2_000, JSON.parse(response.body).fetch("total_tds_minor")

    get tds_form_16a_report_path(@vendor), params: { fiscal_year: 2026, quarter: 2 }
    assert_response :success
    assert_match(/form-16a-fy2026-q2-deductee-#{@vendor.id}\.json/,
      response.headers.fetch("Content-Disposition"))
    assert_equal "16A", JSON.parse(response.body).fetch("form")

    get "/api/v1/reports/tds/form_26q", params: { fiscal_year: 2026, quarter: 2 }
    assert_response :success
    assert_equal 2_000, JSON.parse(response.body).dig("tds_return", "total_tds_minor")

    get "/api/v1/reports/tds/form_16a/#{@vendor.id}", params: {
      fiscal_year: 2026, quarter: 2
    }
    assert_response :success
    assert_equal @vendor.id,
      JSON.parse(response.body).dig("tds_certificate", "deductee", "party_id")
  end

  test "GSTR-3B filing requires reviewed ITC and caps it to the purchase book" do
    post "/api/v1/reports/gst_filing", params: {
      form: "GSTR-3B", tax_registration_id: @registration.id,
      from: "2026-07-01", to: "2026-07-31"
    }
    assert_response :bad_request
    assert_match(/reviewed_itc/, JSON.parse(response.body).fetch("error"))

    post "/api/v1/reports/gst_filing", params: {
      form: "GSTR-3B", tax_registration_id: @registration.id,
      from: "2026-07-01", to: "2026-07-31",
      reviewed_itc: {
        status: "gstr_2b_reconciled",
        available: { igst_minor: 1_800, cgst_minor: 0, sgst_minor: 0, cess_minor: 0 }
      }
    }
    assert_response :success
    filing = JSON.parse(response.body).fetch("gst_filing")
    assert_equal "v7.1", filing.fetch("schema_version")
    assert_equal "DRAFT", filing.fetch("schema_status")
    assert_equal 100, filing.dig("payload", "sup_details", "osup_det", "txval")
    assert_equal 9, filing.dig("payload", "sup_details", "osup_det", "camt")
    assert_equal 18, filing.dig("payload", "itc_elg", "itc_net", "iamt")
    assert_equal "gstr_2b_reconciled", filing.dig("crosscheck", "itc_source")

    post "/api/v1/reports/gst_filing", params: {
      form: "GSTR-3B", tax_registration_id: @registration.id,
      from: "2026-07-01", to: "2026-07-31",
      reviewed_itc: {
        status: "gstr_2b_reconciled",
        available: { igst_minor: 1_801, cgst_minor: 0, sgst_minor: 0, cess_minor: 0 }
      }
    }
    assert_response :unprocessable_entity
    assert_match(/exceeds Folio's purchase-book reference/, JSON.parse(response.body).fetch("error"))
  end

  test "GSTR-3B represents a reversal-heavy period with net-negative ITC" do
    post "/api/v1/reports/gst_filing", params: {
      form: "GSTR-3B", tax_registration_id: @registration.id,
      from: "2026-07-01", to: "2026-07-31",
      reviewed_itc: {
        status: "gstr_2b_reconciled",
        available: { igst_minor: 0, cgst_minor: 0, sgst_minor: 0, cess_minor: 0 },
        reversal_other: { igst_minor: 2_000 }
      }
    }

    assert_response :success
    filing = JSON.parse(response.body).fetch("gst_filing")
    assert_equal(-20, filing.dig("payload", "itc_elg", "itc_net", "iamt"))
    assert_equal(-2_000, filing.dig("crosscheck", "reviewed_itc_minor", "igst"))
  end

  test "CMP-08 filing uses explicitly reviewed quarterly turnover" do
    post "/api/v1/reports/gst_filing", params: {
      form: "CMP-08", tax_registration_id: @registration.id,
      from: "2026-04-01", to: "2026-06-30",
      composition_type: "service", reviewed_turnover_minor: 1_000_000,
      composition_rate_basis_points: 600
    }
    assert_response :success
    filing = JSON.parse(response.body).fetch("gst_filing")
    assert_equal "v1.2", filing.fetch("schema_version")
    assert_equal "N", filing.dig("payload", "isnil")
    assert_equal 10_000, filing.dig("payload", "table3", "out_ser", "tax_val")
    assert_equal 300, filing.dig("payload", "table3", "tax_pay", "camt")
    assert_equal 300, filing.dig("payload", "table3", "tax_pay", "samt")
    assert_equal 60_000, filing.dig("crosscheck", "tax_payable_minor")
  end

  test "GST preparation nets credit notes and negative postings while isolating reversal review" do
    credit_note = CreditNotes::BuildDraft.call(
      tenant: @org.tenant, invoice_id: @invoice.id,
      document_date: Date.new(2026, 7, 31), reason_code: "service_deficiency",
      lines: [ { document_line_id: @invoice.document_lines.first.id, quantity: "0.5" } ]
    )
    Documents::Post.call(credit_note, actor: "u:#{@org.user.id}")
    supplier_credit = PurchaseCreditNotes::BuildDraft.call(
      tenant: @org.tenant, purchase_bill_id: @bill.id,
      document_date: Date.new(2026, 7, 31), external_reference: "V-CN-001",
      reason_code: "service_deficiency",
      lines: [ { document_line_id: @bill.document_lines.first.id, quantity: "0.5" } ]
    )
    Documents::Post.call(supplier_credit, actor: "u:#{@org.user.id}")

    reversed_invoice = SalesInvoices::BuildDraft.call(
      tenant: @org.tenant, party_id: @customer.id, tax_registration_id: @registration.id,
      document_date: Date.new(2026, 7, 31), due_date: Date.new(2026, 8, 30),
      place_of_supply_state_code: "27",
      lines: [ { item_id: @service.id, quantity: "2", unit_price: "50.00" } ]
    )
    Documents::Post.call(reversed_invoice, actor: "u:#{@org.user.id}")
    Documents::Reverse.call(reversed_invoice, actor: "u:#{@org.user.id}", on: Date.new(2026, 7, 31))

    # GST classification must resolve the rebuilt entry ids, not stale document pointers.
    Posting.rebuild!(@org.tenant.id)
    Document.where(tenant_id: @org.tenant.id, state: %w[posted reversed]).find_each do |document|
      assert_equal document.id, Entry.find(document.posted_entry_id).document_id
    end

    report = Reports.gst_returns(
      @org.tenant.id, tax_registration_id: @registration.id,
      from_date: Date.new(2026, 7, 1), to_date: Date.new(2026, 7, 31)
    )
    assert_equal 2, report.dig(:gstr_1, :table_4a_b2b_regular, :document_count)
    assert_equal 1, report.dig(:gstr_1, :table_9b_credit_notes_registered, :document_count)
    assert_equal 1, report.dig(:gstr_1, :internal_reversal_review, :document_count)
    assert_equal(-10_000, report.dig(:gstr_1, :internal_reversal_review, :totals, :taxable_value_minor))
    assert_equal 7_500, report.dig(:gstr_1, :book_adjusted_outward, :taxable_value_minor)
    assert_equal 675, report.dig(:gstr_3b, :table_3_1_a_outward_taxable, :tax, :cgst)
    assert_equal 1, report.dig(:gstr_3b, :table_4_a_5_book_input_tax_reference, :supplier_credit_note_count)
    assert_equal 7_500, report.dig(:gstr_3b, :table_4_a_5_book_input_tax_reference, :taxable_value_minor)
    assert_equal 1_350, report.dig(:gstr_3b, :table_4_a_5_book_input_tax_reference, :tax, :igst)
    assert_equal 3.5.to_d, report.dig(:gstr_1, :hsn_summary, 0, :quantity)

    error = assert_raises(Taxes::India::Gst::Filing::NotReady) do
      Reports.gstr1_filing(
        @org.tenant.id, tax_registration_id: @registration.id,
        from_date: Date.new(2026, 7, 1), to_date: Date.new(2026, 7, 31)
      )
    end
    assert_match(/internal invoice reversal/, error.message)
  end

  test "statutory reports reject invalid periods and cross-tenant registrations" do
    get "/api/v1/reports/day_book", params: { from: "2026-08-01", to: "2026-07-01" }
    assert_response :unprocessable_entity
    assert_match(/from date/, JSON.parse(response.body).fetch("error"))

    other = Onboarding::SignUp.call(
      email: "gst-report-other@folio.invalid",
      password: "correct-horse-battery",
      org_name: "GST Report Other"
    )
    sign_out
    sign_in_as(other.user)
    get "/api/v1/reports/gst_summary", params: {
      tax_registration_id: @registration.id, from: "2026-07-01", to: "2026-07-31"
    }
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
