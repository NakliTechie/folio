# frozen_string_literal: true

require "test_helper"

class SalesInvoiceFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "sales-invoice-flow@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Sales Invoice Flow"
    )
    @entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @seller_registration = TaxRegistrations::Manage.create!(
      tenant: @org.tenant,
      entity: @entity,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2026, 4, 1)
      },
      office_ids: [ @office.id ],
      actor: @org.user
    )
    @customer = Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        party_number: "C-001", name: "Acme Customer", state_code: "29", country_code: "IN"
      },
      roles: [ "customer" ],
      tax_registration_attributes: {
        kind: "GSTIN", identifier: "29AAAAA0300L1Z8", valid_from: Date.new(2026, 4, 1)
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
    sign_in_as(@org.user)
  end

  test "owner creates reviews and posts a B2B service invoice in the browser" do
    get new_sales_invoice_path
    assert_response :success
    assert_select "h1", "Create a sales invoice"
    assert_select "option", text: /Acme Customer/
    assert_select "option", text: /27AAPFU0939F1ZV/
    assert_select "option", text: /Consulting services/

    assert_difference -> { Document.where(tenant_id: @org.tenant.id, doc_type: "SI").count }, 1 do
      post sales_invoices_path, params: browser_invoice_params(place_of_supply_state_code: "27")
    end
    invoice = Document.where(tenant_id: @org.tenant.id, doc_type: "SI").order(:id).last
    assert_redirected_to sales_invoice_path(invoice, tenant_id: @org.tenant.id)

    follow_redirect!
    assert_response :success
    assert_select "h1", "Draft invoice"
    assert_select "th", text: "CGST"
    assert_select "th", text: "SGST"
    assert_select "td", text: /INR 118\.00/
    assert_select "button", text: "Post invoice"

    post post_sales_invoice_path(invoice)
    assert_redirected_to sales_invoice_path(invoice, tenant_id: @org.tenant.id)
    assert_equal "posted", invoice.reload.state
    assert_equal "SI/1", invoice.document_number
    assert_equal 4, Entry.find(invoice.posted_entry_id).entry_lines.count

    get sales_invoices_path
    assert_response :success
    assert_select "td", text: /SI\/1/
    assert_select "td", text: /Acme Customer/
  end

  test "operator can create and post invoices without journal-voucher permission" do
    operator = invite_user("sales-invoice-operator@folio.invalid", "operator")
    sign_out
    sign_in_as(operator)

    refute Authorization.permits?(
      user: operator, tenant_id: @org.tenant.id, capability: "documents.post"
    )
    assert Authorization.permits?(
      user: operator, tenant_id: @org.tenant.id, capability: "invoices.create"
    )

    post sales_invoices_path, params: browser_invoice_params
    invoice = Document.where(tenant_id: @org.tenant.id, doc_type: "SI").order(:id).last
    assert_redirected_to sales_invoice_path(invoice, tenant_id: @org.tenant.id)

    post post_sales_invoice_path(invoice)
    assert_redirected_to sales_invoice_path(invoice, tenant_id: @org.tenant.id)
    assert_equal "posted", invoice.reload.state
    entry = Entry.find(invoice.posted_entry_id)
    assert_equal "operator", RoleTemplate.find(entry.role_template_id).code
  end

  test "viewer may inspect invoices but cannot create them" do
    invoice = SalesInvoices::BuildDraft.call(**builder_attributes)
    viewer = invite_user("sales-invoice-viewer@folio.invalid", "viewer")
    sign_out
    sign_in_as(viewer)

    get sales_invoices_path
    assert_response :success
    get sales_invoice_path(invoice)
    assert_response :success
    get new_sales_invoice_path
    assert_redirected_to root_path(tenant_id: @org.tenant.id)

    assert_no_difference "Document.count" do
      post "/api/v1/sales_invoices", params: api_invoice_params
    end
    assert_response :forbidden
  end

  test "JSON invoice endpoints calculate IGST post and remain tenant scoped" do
    post "/api/v1/sales_invoices", params: api_invoice_params
    assert_response :created
    json = JSON.parse(response.body).fetch("sales_invoice")
    assert_equal "draft", json.fetch("state")
    assert_equal 10_000, json.fetch("subtotal_minor")
    assert_equal({ "igst" => 1_800 }, json.fetch("tax_breakdown"))
    assert_equal "998311", json.fetch("lines").first.fetch("hsn_sac_code")
    invoice_id = json.fetch("id")

    post "/api/v1/sales_invoices/#{invoice_id}/post"
    assert_response :success
    posted = JSON.parse(response.body).fetch("sales_invoice")
    assert_equal "posted", posted.fetch("state")
    assert_equal "SI/1", posted.fetch("document_number")

    other = Onboarding::SignUp.call(
      email: "sales-invoice-other@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Sales Invoice Other"
    )
    sign_out
    sign_in_as(other.user)
    get "/api/v1/sales_invoices/#{invoice_id}"
    assert_response :not_found
  end

  private

  def browser_invoice_params(place_of_supply_state_code: "29")
    {
      sales_invoice: {
        party_id: @customer.id,
        tax_registration_id: @seller_registration.id,
        document_date: "2026-07-31",
        due_date: "2026-08-30",
        place_of_supply_state_code: place_of_supply_state_code,
        external_reference: "PO-001",
        narration: "July consulting",
        lines: [ { item_id: @service.id, quantity: "2", unit_price: "50.00" } ]
      }
    }
  end

  def api_invoice_params
    browser_invoice_params.fetch(:sales_invoice)
  end

  def builder_attributes
    api_invoice_params.merge(tenant: @org.tenant)
  end

  def invite_user(email, role_code)
    invitation = Onboarding::Invite.create!(
      tenant: @org.tenant, email: email, role_code: role_code, invited_by: @org.user
    )
    Onboarding::Invite.accept!(
      token: invitation.generate_token_for(:invite), password: "correct-horse-battery"
    )
  end
end
