# frozen_string_literal: true

require "application_system_test_case"

class WalkthroughTest < ApplicationSystemTestCase
  PASSWORD = "walkthrough-password-2026"

  test "anonymous signup and duplicate-email recovery" do
    visit root_path
    assert_current_path new_session_path
    assert_selector "h1", text: "Sign in to Folio"

    click_link "Create an account"
    fill_in "Company name", with: "Walkthrough Books"
    fill_in "Email", with: "walkthrough-owner@folio.invalid"
    fill_in "Password", with: PASSWORD
    click_button "Create company books"

    assert_current_path root_path, wait: 15
    assert_selector "[role=status]", text: "Welcome to Folio — Walkthrough Books is ready."
    assert_text "Signed in as walkthrough-owner@folio.invalid."
    assert_selector "h1", text: "Your books, at a glance"

    click_button "Sign out"
    click_link "Create an account"
    fill_in "Company name", with: "Preserved Company"
    fill_in "Email", with: "walkthrough-owner@folio.invalid"
    fill_in "Password", with: PASSWORD
    click_button "Create company books"

    assert_selector "[role=alert]", text: "Email address has already been taken"
    assert_field "Company name", with: "Preserved Company"
    assert_field "Email", with: "walkthrough-owner@folio.invalid"
    assert_field "Password", with: ""
  end

  test "new owner records a balanced voucher and reaches first value" do
    visit new_registration_path
    fill_in "Company name", with: "First Value Books"
    fill_in "Email", with: "first-value@folio.invalid"
    fill_in "Password", with: PASSWORD
    select "India", from: "Country or jurisdiction"
    select "INR — Indian rupee", from: "Functional currency"
    select "April–March", from: "Fiscal year"
    click_button "Create company books"

    assert_current_path root_path, wait: 15

    click_link "Record your first transaction"
    set_date_field "Posting date", "2026-07-30"
    fill_in "What is this transaction for?", with: "Owner capital introduced"
    fill_in "Amount (INR)", with: "1250.50"
    select "1000 · Cash", from: "Debit account"
    select "3000 · Capital", from: "Credit account"
    click_button "Review voucher"

    assert_selector "h2", text: "Balanced and ready to post"
    assert_text "INR 1,250.50"
    click_button "Post voucher"

    assert_current_path reports_path, ignore_query: true
    assert_selector "h1", text: "Trial balance"
    assert_selector "[role=status]", text: /posted.*trial balance/i
    assert_selector "tr.table-row--highlight", count: 2

    click_link "Period close"
    assert_selector "h1", text: "Period close"
    assert_selector ".metric-card__label", text: /Ledger balance/i
    assert_selector ".metric-card__label", text: /Audit chain/i
    click_button "Restrict to close team"
    assert_selector "[role=status]", text: /posting period is now restricted/i
    assert_selector ".status-badge", text: "Restricted"
  end

  test "owner migrates opening balances and reads versioned financial statements" do
    visit new_registration_path
    fill_in "Company name", with: "Migration Books"
    fill_in "Email", with: "migration@folio.invalid"
    fill_in "Password", with: PASSWORD
    click_button "Create company books"

    assert_current_path root_path, wait: 15

    click_link "Chart of accounts"
    click_link "Opening balances"
    click_link "Enter opening balances"
    fill_in "Cutover date", with: "2026-04-01"
    fill_in "Description", with: "Legacy books cutover"
    fill_in "Debit for 1000", with: "5000.00"
    fill_in "Credit for 3000", with: "5000.00"
    click_button "Review opening balances"

    assert_selector "h2", text: "Balanced and ready to post"
    assert_text "INR 5,000.00"
    click_button "Post opening balances"

    assert_current_path balance_sheet_report_path, ignore_query: true
    assert_selector "h1", text: "Balance sheet"
    assert_selector "tfoot", text: "Balanced"
    assert_text "Default financial statements · version 1"

    click_link "Profit & loss"
    assert_current_path profit_and_loss_report_path, ignore_query: true
    assert_selector "h1", text: "Profit & loss"
    assert_selector "tfoot", text: "Net profit"
  end

  test "service business creates posts and reverses a GST sales invoice" do
    org = Onboarding::SignUp.call(
      email: "invoice-walkthrough@folio.invalid", password: PASSWORD, org_name: "Invoice Walkthrough"
    )
    entity = Entity.find_by!(tenant_id: org.tenant.id, code: "PRIMARY")
    office = Office.find_by!(tenant_id: org.tenant.id, code: "PRIMARY")
    registration = TaxRegistrations::Manage.create!(
      tenant: org.tenant, entity: entity,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2026, 4, 1)
      },
      office_ids: [ office.id ], actor: org.user
    )
    Parties::Manage.create!(
      tenant: org.tenant,
      attributes: {
        party_number: "C-001", name: "Acme Customer", state_code: "29", country_code: "IN",
        address_line1: "2 Customer Road", city: "Bengaluru", postal_code: "560001"
      },
      roles: [ "customer" ],
      tax_registration_attributes: {
        kind: "GSTIN", identifier: "29AAAAA0300L1Z8", valid_from: Date.new(2026, 4, 1)
      },
      actor: org.user
    )
    Items::Manage.create!(
      tenant: org.tenant,
      attributes: {
        code: "CONSULT", name: "Consulting services", item_type: "service",
        hsn_sac_code: "998311", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
        cess_rate_basis_points: 0, income_account_code: "4000", expense_account_code: "5000"
      },
      actor: org.user
    )

    visit new_session_path
    fill_in "Email", with: org.user.email_address
    fill_in "Password", with: PASSWORD
    click_button "Sign in"
    click_link "Tax setup"
    click_link "Company details"
    fill_in "Address line 1", with: "1 Ledger Lane"
    fill_in "City", with: "Mumbai"
    fill_in "PIN code", with: "400001"
    select "27", from: "GST state code"
    fill_in "Country code", with: "IN"
    click_button "Save company details"
    assert_selector "[role=status]", text: /Company details updated/

    click_link "Sales invoices"
    click_link "New sales invoice"
    select "C-001 · Acme Customer", from: "Customer"
    select "27AAPFU0939F1ZV · State 27", from: "Seller GSTIN"
    set_date_field "Invoice date", "2026-07-31"
    set_date_field "Due date", "2026-08-30"
    select "29 · GST state/UT", from: "Place of supply (state code)"
    select "CONSULT · Consulting services", from: "Product or service for line 1"
    fill_in "Quantity for line 1", with: "2"
    fill_in "Unit price for line 1", with: "50.00"
    click_button "Review invoice"

    assert_selector "h2", text: "GST calculated and ready to post"
    assert_text "IGST"
    assert_text "INR 118.00"
    click_button "Post invoice"

    assert_selector "h1", text: "SI/26-27/00001"
    assert_selector "[role=status]", text: /posted.*receivables.*GST/i
    click_link "Print invoice"
    assert_selector ".invoice-document", text: /TAX INVOICE/
    assert_selector ".invoice-document", text: /SI\/26-27\/00001/
    assert_text "Karnataka (29)"
    click_link "← Back to invoice"
    accept_confirm("Reverse this unsettled invoice with a compensating entry?") do
      click_button "Reverse invoice"
    end

    assert_selector "[role=status]", text: /reversed.*open receivable cleared/i
    assert_selector ".status-badge--danger", text: "Reversed"

    visit gst_summary_report_path(
      tenant_id: org.tenant.id, tax_registration_id: registration.id,
      from: "2026-07-01", to: "2026-07-31"
    )
    assert_selector "h1", text: "GSTR-1 and GSTR-3B preparation"
    assert_text "Internal reversal review required"
    click_link "Day book"
    assert_selector "h1", text: "Day book"
  end

  test "owner issues and prints a partial credit note" do
    setup = create_posted_invoice("credit-walkthrough@folio.invalid", "Credit Walkthrough")

    visit new_session_path
    fill_in "Email", with: setup.fetch(:org).user.email_address
    fill_in "Password", with: PASSWORD
    click_button "Sign in"
    assert_text "Signed in as #{setup.fetch(:org).user.email_address}.", wait: 5
    visit sales_invoice_path(
      setup.fetch(:invoice), tenant_id: setup.fetch(:org).tenant.id
    )
    click_link "Issue credit note"
    set_date_field "Credit-note date", "2026-08-01"
    select "Service deficiency", from: "Reason"
    fill_in "Explanation", with: "Service-level adjustment"
    fill_in "Quantity to credit for line 1", with: "0.5"
    click_button "Review credit note"

    assert_selector "h2", text: "Balanced and ready to post"
    assert_text "INR 29.50"
    click_button "Post credit note"

    assert_selector "h1", text: "CN/26-27/00001"
    assert_selector "[role=status]", text: /posted.*applied.*receivable/i
    click_link "Print credit note"
    assert_selector ".invoice-document", text: /CREDIT NOTE/
    assert_selector ".invoice-document", text: /CN\/26-27\/00001/
    assert_text "SI/26-27/00001"
  end

  test "service business records and reverses a governed purchase bill" do
    org = Onboarding::SignUp.call(
      email: "purchase-walkthrough@folio.invalid", password: PASSWORD, org_name: "Purchase Walkthrough"
    )
    entity = Entity.find_by!(tenant_id: org.tenant.id, code: "PRIMARY")
    office = Office.find_by!(tenant_id: org.tenant.id, code: "PRIMARY")
    office.update!(
      address_line1: "1 Ledger Lane", city: "Mumbai", postal_code: "400001",
      state_code: "27", country_code: "IN"
    )
    TaxRegistrations::Manage.create!(
      tenant: org.tenant, entity: entity,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2026, 4, 1)
      },
      office_ids: [ office.id ], actor: org.user
    )
    Parties::Manage.create!(
      tenant: org.tenant,
      attributes: {
        party_number: "V-001", name: "Acme Vendor", state_code: "29", country_code: "IN",
        address_line1: "2 Supplier Road", city: "Bengaluru", postal_code: "560001"
      },
      roles: [ "vendor" ],
      tax_registration_attributes: {
        kind: "GSTIN", identifier: "29AAAAA0300L1Z8", valid_from: Date.new(2026, 4, 1)
      },
      actor: org.user
    )
    Items::Manage.create!(
      tenant: org.tenant,
      attributes: {
        code: "LEGAL", name: "Legal services", item_type: "service",
        hsn_sac_code: "998211", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
        cess_rate_basis_points: 0, income_account_code: "4000", expense_account_code: "5000"
      },
      actor: org.user
    )

    visit new_session_path
    fill_in "Email", with: org.user.email_address
    fill_in "Password", with: PASSWORD
    click_button "Sign in"
    click_link "Purchases"
    click_link "New purchase bill"
    select "V-001 · Acme Vendor", from: "Vendor"
    select "27AAPFU0939F1ZV · State 27", from: "Buyer GSTIN"
    fill_in "Supplier invoice number", with: "V-INV-1042"
    set_date_field "Supplier invoice date", "2026-07-31"
    set_date_field "Due date", "2026-08-30"
    select "27 · Maharashtra", from: "Place of supply (state code)"
    select "LEGAL · Legal services", from: "Product or service for line 1"
    fill_in "Quantity for line 1", with: "2"
    fill_in "Unit price for line 1", with: "50.00"
    click_button "Review bill"

    assert_selector "h2", text: "Input GST calculated and ready to post"
    assert_text "IGST input credit"
    assert_text "INR 118.00"
    click_button "Post bill"

    assert_selector "h1", text: "PB/26-27/00001"
    assert_selector "[role=status]", text: /posted.*Payables.*input GST/i
    accept_confirm("Reverse this unsettled bill with a compensating entry?") do
      click_button "Reverse bill"
    end
    assert_selector "[role=status]", text: /reversed.*open payable cleared/i
    assert_selector ".status-badge--danger", text: "Reversed"
  end

  test "owner records a partial supplier credit against a posted purchase bill" do
    setup = create_posted_purchase_bill("supplier-credit-walkthrough@folio.invalid", "Supplier Credit Walkthrough")

    visit new_session_path
    fill_in "Email", with: setup.fetch(:org).user.email_address
    fill_in "Password", with: PASSWORD
    click_button "Sign in"
    assert_text "Signed in as #{setup.fetch(:org).user.email_address}.", wait: 5
    visit purchase_bill_path(setup.fetch(:bill), tenant_id: setup.fetch(:org).tenant.id)
    click_link "Record supplier credit"
    fill_in "Supplier credit-note number", with: "V-CN-1042"
    set_date_field "Supplier credit-note date", "2026-08-01"
    select "Service deficiency", from: "Reason"
    fill_in "Explanation", with: "Service-level adjustment"
    fill_in "Quantity credited for line 1", with: "0.5"
    click_button "Review supplier credit"

    assert_selector "h2", text: "Balanced and ready to post"
    assert_text "INR 29.50"
    click_button "Post supplier credit"

    assert_selector "h1", text: "PC/26-27/00001"
    assert_selector "[role=status]", text: /posted.*applied.*purchase-bill payable/i
    assert_text "V-CN-1042"
    click_link "Open source purchase bill"
    assert_selector "h1", text: "PB/26-27/00001"
    assert_no_button "Reverse bill"
  end

  test "service business allocates a partial customer receipt without resetting ageing" do
    setup = create_posted_invoice("receipt-walkthrough@folio.invalid", "Receipt Walkthrough")
    invoice = setup.fetch(:invoice)

    visit new_session_path
    fill_in "Email", with: setup.fetch(:org).user.email_address
    fill_in "Password", with: PASSWORD
    click_button "Sign in"
    click_link "Cash"
    click_link "Record receipt"
    set_date_field "Settlement date", "2026-08-15"
    select "1010 · Bank", from: "Cash or bank account"
    fill_in "Amount for SI:#{invoice.id}", with: "40.00"
    select "Preserve ageing", from: "Remaining-balance treatment for SI:#{invoice.id}"
    click_button "Review customer receipt"

    assert_selector "h1", text: "Draft customer receipt"
    assert_text "INR 40.00"
    assert_text "Preserve original ageing"
    click_button "Post customer receipt"

    assert_selector "h1", text: "RC/26-27/00001"
    assert_selector "[role=status]", text: /posted.*allocations.*applied/i
    allocation = Document.find_by!(tenant_id: setup.fetch(:org).tenant.id, doc_type: "RC")
      .document_allocations.first
    assert_equal 7_800, Posting::Clearing.open_amount(allocation.target_item)
    assert_nil allocation.target_item.cleared_on

    visit aged_receivables_report_path(
      tenant_id: setup.fetch(:org).tenant.id, aged_to: "2026-09-30"
    )
    assert_selector "h1", text: "Aged receivables"
    assert_text "INR 78.00"
    click_link "Party ledger"
    assert_selector "tbody tr", count: 2

    visit settlement_path(allocation.document, tenant_id: setup.fetch(:org).tenant.id)
    accept_confirm("Reset this allocation and reopen the cash as unapplied?") do
      click_button "Reset allocation 1"
    end
    assert_selector "[role=status]", text: /cash is now unapplied/i
    click_link "Reallocate unapplied cash"
    select "SI/26-27/00001 · INR 118.00", from: "New open item"
    select "Preserve ageing", from: "Remaining-balance treatment"
    click_button "Apply reallocation"
    assert_text "Reapplied to SI/26-27/00001"
  end

  test "every RBAC preset can enter and leave its authenticated landing" do
    org = Onboarding::SignUp.call(
      email: "role-owner@folio.invalid", password: PASSWORD, org_name: "Role Walkthrough"
    )
    users = { "owner" => org.user }
    Rbac::Presets::MATRIX.each_key do |role_code|
      next if role_code == "owner"

      invitation = Onboarding::Invite.create!(
        tenant: org.tenant, email: "role-#{role_code.tr("_", "-")}@folio.invalid",
        role_code: role_code, invited_by: org.user
      )
      users[role_code] = Onboarding::Invite.accept!(
        token: invitation.generate_token_for(:invite), password: PASSWORD
      )
    end

    users.each do |role_code, user|
      visit new_session_path
      fill_in "Email", with: user.email_address
      fill_in "Password", with: PASSWORD
      click_button "Sign in"

      assert_current_path root_path
      assert_text "Signed in as #{user.email_address}.", wait: 5
      click_button "Sign out"
      assert_current_path new_session_path
    end
  end

  private

  def set_date_field(label, value)
    field = find_field(label)
    page.execute_script(<<~JS, field.native, value)
      arguments[0].value = arguments[1];
      arguments[0].dispatchEvent(new Event("input", { bubbles: true }));
      arguments[0].dispatchEvent(new Event("change", { bubbles: true }));
    JS
  end

  def create_posted_invoice(email, org_name)
    org = Onboarding::SignUp.call(email: email, password: PASSWORD, org_name: org_name)
    entity = Entity.find_by!(tenant_id: org.tenant.id, code: "PRIMARY")
    office = Office.find_by!(tenant_id: org.tenant.id, code: "PRIMARY")
    office.update!(
      address_line1: "1 Ledger Lane", city: "Mumbai", postal_code: "400001",
      state_code: "27", country_code: "IN"
    )
    registration = TaxRegistrations::Manage.create!(
      tenant: org.tenant, entity: entity,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2026, 4, 1)
      },
      office_ids: [ office.id ], actor: org.user
    )
    customer = Parties::Manage.create!(
      tenant: org.tenant,
      attributes: {
        party_number: "C-001", name: "Acme Customer", state_code: "27", country_code: "IN",
        address_line1: "2 Customer Road", city: "Mumbai", postal_code: "400002"
      },
      roles: [ "customer" ],
      tax_registration_attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", valid_from: Date.new(2026, 4, 1)
      },
      actor: org.user
    )
    service = Items::Manage.create!(
      tenant: org.tenant,
      attributes: {
        code: "CONSULT", name: "Consulting services", item_type: "service",
        hsn_sac_code: "998311", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
        cess_rate_basis_points: 0, income_account_code: "4000", expense_account_code: "5000"
      },
      actor: org.user
    )
    invoice = SalesInvoices::BuildDraft.call(
      tenant: org.tenant, party_id: customer.id, tax_registration_id: registration.id,
      document_date: Date.new(2026, 7, 31), due_date: Date.new(2026, 8, 30),
      place_of_supply_state_code: "27",
      lines: [ { item_id: service.id, quantity: "2", unit_price: "50.00" } ]
    )
    Documents::Post.call(invoice, actor: "u:#{org.user.id}")
    { org: org, invoice: invoice }
  end

  def create_posted_purchase_bill(email, org_name)
    org = Onboarding::SignUp.call(email: email, password: PASSWORD, org_name: org_name)
    entity = Entity.find_by!(tenant_id: org.tenant.id, code: "PRIMARY")
    office = Office.find_by!(tenant_id: org.tenant.id, code: "PRIMARY")
    office.update!(
      address_line1: "1 Ledger Lane", city: "Mumbai", postal_code: "400001",
      state_code: "27", country_code: "IN"
    )
    registration = TaxRegistrations::Manage.create!(
      tenant: org.tenant, entity: entity,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2026, 4, 1)
      },
      office_ids: [ office.id ], actor: org.user
    )
    vendor = Parties::Manage.create!(
      tenant: org.tenant,
      attributes: {
        party_number: "V-001", name: "Acme Vendor", state_code: "27", country_code: "IN",
        address_line1: "2 Supplier Road", city: "Mumbai", postal_code: "400002"
      },
      roles: [ "vendor" ],
      tax_registration_attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", valid_from: Date.new(2026, 4, 1)
      },
      actor: org.user
    )
    service = Items::Manage.create!(
      tenant: org.tenant,
      attributes: {
        code: "LEGAL", name: "Legal services", item_type: "service",
        hsn_sac_code: "998211", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
        cess_rate_basis_points: 0, income_account_code: "4000", expense_account_code: "5000"
      },
      actor: org.user
    )
    bill = PurchaseBills::BuildDraft.call(
      tenant: org.tenant, party_id: vendor.id, tax_registration_id: registration.id,
      document_date: Date.new(2026, 7, 31), due_date: Date.new(2026, 8, 30),
      place_of_supply_state_code: "27", external_reference: "V-INV-1042",
      lines: [ { item_id: service.id, quantity: "2", unit_price: "50.00" } ]
    )
    Documents::Post.call(bill, actor: "u:#{org.user.id}")
    { org: org, bill: bill }
  end
end
