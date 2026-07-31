# frozen_string_literal: true

require "test_helper"

class CreditNoteFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "credit-note-flow@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Credit Note Flow"
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
    customer = Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        party_number: "C-001", name: "Acme Customer", state_code: "29", country_code: "IN",
        address_line1: "2 Customer Road", city: "Bengaluru", postal_code: "560001"
      },
      roles: [ "customer" ],
      tax_registration_attributes: {
        kind: "GSTIN", identifier: "29AAAAA0300L1Z8", valid_from: Date.new(2026, 4, 1)
      },
      actor: @org.user
    )
    service = Items::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        code: "CONSULT", name: "Consulting services", item_type: "service",
        hsn_sac_code: "998311", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
        cess_rate_basis_points: 0, income_account_code: "4000", expense_account_code: "5000"
      },
      actor: @org.user
    )
    @invoice = SalesInvoices::BuildDraft.call(
      tenant: @org.tenant, party_id: customer.id, tax_registration_id: registration.id,
      document_date: Date.new(2026, 7, 31), due_date: Date.new(2026, 8, 30),
      place_of_supply_state_code: "29",
      lines: [ { item_id: service.id, quantity: "2", unit_price: "50.00" } ]
    )
    Documents::Post.call(@invoice, actor: "u:#{@org.user.id}")
    sign_in_as(@org.user)
  end

  test "owner issues posts and prints a partial credit note in the browser" do
    get sales_invoice_path(@invoice)
    assert_response :success
    assert_select "a", text: "Issue credit note"

    get new_credit_note_path(invoice_id: @invoice.id)
    assert_response :success
    assert_select "h1", text: "Credit SI/26-27/00001"
    assert_select "td", text: /Consulting services/

    assert_difference -> { Document.where(tenant_id: @org.tenant.id, doc_type: "CN").count }, 1 do
      post credit_notes_path, params: browser_params
    end
    note = Document.where(tenant_id: @org.tenant.id, doc_type: "CN").order(:id).last
    assert_redirected_to credit_note_path(note, tenant_id: @org.tenant.id)
    follow_redirect!
    assert_select "h2", text: "Balanced and ready to post"
    assert_select "td", text: /INR 25\.00/

    post post_credit_note_path(note)
    assert_redirected_to credit_note_path(note, tenant_id: @org.tenant.id)
    assert_equal "CN/26-27/00001", note.reload.document_number

    get print_credit_note_path(note)
    assert_response :success
    assert_select ".invoice-document", text: /CN\/26-27\/00001/
    assert_select ".invoice-document", text: /SI\/26-27\/00001/
    assert_select ".invoice-document", text: /Karnataka \(29\)/
  end

  test "operator can use JSON credit-note endpoints and tenant boundaries remain opaque" do
    operator = invite_user("credit-note-operator@folio.invalid", "operator")
    sign_out
    sign_in_as(operator)

    post "/api/v1/credit_notes", params: api_params
    assert_response :created
    json = JSON.parse(response.body).fetch("credit_note")
    assert_equal @invoice.id, json.fetch("source_invoice_id")
    assert_equal 2_500, json.fetch("subtotal_minor")
    note_id = json.fetch("id")

    post "/api/v1/credit_notes/#{note_id}/post"
    assert_response :success
    assert_equal "CN/26-27/00001", JSON.parse(response.body).dig("credit_note", "document_number")

    other = Onboarding::SignUp.call(
      email: "credit-note-other@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Credit Note Other"
    )
    sign_out
    sign_in_as(other.user)
    get "/api/v1/credit_notes/#{note_id}"
    assert_response :not_found
  end

  test "viewer can inspect credit notes but cannot create them" do
    note = CreditNotes::BuildDraft.call(**builder_params)
    viewer = invite_user("credit-note-viewer@folio.invalid", "viewer")
    sign_out
    sign_in_as(viewer)

    get credit_note_path(note)
    assert_response :success
    get new_credit_note_path(invoice_id: @invoice.id)
    assert_redirected_to root_path(tenant_id: @org.tenant.id)
    assert_no_difference "Document.count" do
      post "/api/v1/credit_notes", params: api_params
    end
    assert_response :forbidden
  end

  private

  def browser_params
    { credit_note: api_params }
  end

  def api_params
    {
      invoice_id: @invoice.id,
      document_date: "2026-08-01",
      reason_code: "service_deficiency",
      narration: "Service-level adjustment",
      lines: [ { document_line_id: @invoice.document_lines.first.id, quantity: "0.5" } ]
    }
  end

  def builder_params
    api_params.merge(tenant: @org.tenant)
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
