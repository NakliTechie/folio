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

    assert_current_path root_path
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

    click_link "Record your first transaction"
    fill_in "Posting date", with: "2026-07-30"
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
  end

  test "owner migrates opening balances and reads versioned financial statements" do
    visit new_registration_path
    fill_in "Company name", with: "Migration Books"
    fill_in "Email", with: "migration@folio.invalid"
    fill_in "Password", with: PASSWORD
    click_button "Create company books"

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
        party_number: "C-001", name: "Acme Customer", state_code: "29", country_code: "IN"
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
    click_link "Sales invoices"
    click_link "New sales invoice"
    select "C-001 · Acme Customer", from: "Customer"
    select "27AAPFU0939F1ZV · State 27", from: "Seller GSTIN"
    fill_in "Invoice date", with: "2026-07-31"
    fill_in "Due date", with: "2026-08-30"
    select "29 · GST state/UT", from: "Place of supply (state code)"
    select "CONSULT · Consulting services", from: "Product or service for line 1"
    fill_in "Quantity for line 1", with: "2"
    fill_in "Unit price for line 1", with: "50.00"
    click_button "Review invoice"

    assert_selector "h2", text: "GST calculated and ready to post"
    assert_text "IGST"
    assert_text "INR 118.00"
    click_button "Post invoice"

    assert_selector "h1", text: "SI/1"
    assert_selector "[role=status]", text: /posted.*receivables.*GST/i
    accept_confirm("Reverse this unsettled invoice with a compensating entry?") do
      click_button "Reverse invoice"
    end

    assert_selector "[role=status]", text: /reversed.*open receivable cleared/i
    assert_selector ".status-badge--danger", text: "Reversed"
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
end
