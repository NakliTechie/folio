# frozen_string_literal: true

require "test_helper"

class PurchaseDebitNoteFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "purchase-debit-flow@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Purchase Debit Flow"
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
    @vendor = Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        party_number: "V-001", name: "Acme Vendor", state_code: "29", country_code: "IN",
        address_line1: "2 Supplier Road", city: "Bengaluru", postal_code: "560001"
      },
      roles: [ "vendor" ],
      tax_registration_attributes: {
        kind: "GSTIN", identifier: "29AAAAA0300L1Z8", valid_from: Date.new(2026, 4, 1)
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
    @bill = PurchaseBills::BuildDraft.call(
      tenant: @org.tenant, party_id: @vendor.id, tax_registration_id: @registration.id,
      document_date: Date.new(2026, 7, 31), due_date: Date.new(2026, 8, 30),
      place_of_supply_state_code: "27", external_reference: "V-INV-001",
      place_of_supply_override_reason: "Supplier invoice identifies the Maharashtra recipient location",
      actor: @org.user,
      lines: [ { item_id: @service.id, quantity: "2", unit_price: "50.00" } ]
    )
    Documents::Post.call(@bill, actor: "u:#{@org.user.id}")
    sign_in_as(@org.user)
  end

  test "owner records reviews and posts a supplier debit in the browser" do
    get new_purchase_debit_note_path, params: { purchase_bill_id: @bill.id }
    assert_response :success
    assert_select "h1", "Increase PB/26-27/00001"
    assert_select "input[name='purchase_debit_note[external_reference]']"

    assert_difference -> { Document.where(tenant_id: @org.tenant.id, doc_type: "PD").count }, 1 do
      post purchase_debit_notes_path, params: { purchase_debit_note: note_params }
    end
    note = Document.where(tenant_id: @org.tenant.id, doc_type: "PD").order(:id).last
    assert_redirected_to purchase_debit_note_path(note, tenant_id: @org.tenant.id)

    follow_redirect!
    assert_response :success
    assert_select "h1", "Draft supplier debit"
    assert_select "th", text: /IGST input-tax increase/
    assert_select "td", text: /INR 29\.50/
    assert_select "dd", text: "Quantity omitted from supplier bill"
    assert_select "button", text: "Post supplier debit"
    assert_select "button", text: "Discard draft"

    post post_purchase_debit_note_path(note)
    assert_redirected_to purchase_debit_note_path(note, tenant_id: @org.tenant.id)
    assert_equal "posted", note.reload.state
    assert_equal "PD/26-27/00001", note.document_number
    assert_equal 3, Entry.find(note.posted_entry_id).entry_lines.count

    get purchase_debit_notes_path
    assert_response :success
    assert_select "td", text: /PD\/26-27\/00001/
    assert_select "td", text: /V-DN-001/
    assert_select "td", text: /Acme Vendor/

    get purchase_debit_note_path(note)
    assert_select "a", text: "Correct with supplier credit"
  end

  test "operator creates and posts supplier debits through the JSON API" do
    operator = invite_user("purchase-debit-operator@folio.invalid", "operator")
    sign_out
    sign_in_as(operator)

    post "/api/v1/purchase_debit_notes", params: api_note_params
    assert_response :created
    json = JSON.parse(response.body).fetch("purchase_debit_note")
    assert_equal({ "igst" => 450 }, json.fetch("tax_breakdown"))
    assert_equal "V-DN-001", json.fetch("supplier_debit_note_number")
    assert_equal @bill.id, json.fetch("source_purchase_bill_id")
    assert_equal "Quantity omitted from supplier bill", json.fetch("explanation")

    post "/api/v1/purchase_debit_notes/#{json.fetch("id")}/post"
    assert_response :success
    posted = JSON.parse(response.body).fetch("purchase_debit_note")
    assert_equal "PD/26-27/00001", posted.fetch("document_number")
    assert_equal "operator", RoleTemplate.find(Entry.find_by!(document_id: json.fetch("id")).role_template_id).code
  end

  test "a draft can be discarded and its supplier reference reused" do
    note = PurchaseDebitNotes::BuildDraft.call(tenant: @org.tenant, **api_note_params)

    assert_difference -> { Document.where(id: note.id).count }, -1 do
      delete purchase_debit_note_path(note)
    end
    assert_redirected_to purchase_debit_notes_path(tenant_id: @org.tenant.id)

    replacement = PurchaseDebitNotes::BuildDraft.call(tenant: @org.tenant, **api_note_params)
    assert_equal "V-DN-001", replacement.external_reference
  end

  test "tampered source recovery redirects safely and non-finite API input is a validation error" do
    assert_no_difference "Document.count" do
      post purchase_debit_notes_path, params: {
        purchase_debit_note: note_params.merge(purchase_bill_id: "missing")
      }
    end
    assert_redirected_to purchase_bills_path(tenant_id: @org.tenant.id)

    assert_no_difference "Document.count" do
      post "/api/v1/purchase_debit_notes", params: api_note_params.merge(
        lines: [ { document_line_id: @bill.document_lines.first.id, quantity: "Infinity" } ]
      )
    end
    assert_response :unprocessable_entity
    assert_match(/finite/, JSON.parse(response.body).fetch("error"))
  end

  test "viewer may inspect supplier debits but cannot create them and tenant access is isolated" do
    note = PurchaseDebitNotes::BuildDraft.call(tenant: @org.tenant, **api_note_params)
    viewer = invite_user("purchase-debit-viewer@folio.invalid", "viewer")
    sign_out
    sign_in_as(viewer)

    get purchase_debit_notes_path
    assert_response :success
    get purchase_debit_note_path(note)
    assert_response :success
    get new_purchase_debit_note_path, params: { purchase_bill_id: @bill.id }
    assert_redirected_to root_path(tenant_id: @org.tenant.id)

    assert_no_difference "Document.count" do
      post "/api/v1/purchase_debit_notes", params: api_note_params.merge(external_reference: "V-DN-002")
    end
    assert_response :forbidden

    other = Onboarding::SignUp.call(
      email: "purchase-debit-other@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Purchase Debit Other"
    )
    sign_out
    sign_in_as(other.user)
    get "/api/v1/purchase_debit_notes/#{note.id}"
    assert_response :not_found
  end

  private

  def note_params
    {
      purchase_bill_id: @bill.id,
      document_date: "2026-08-01",
      external_reference: "V-DN-001",
      reason_code: "quantity_underbilling",
      narration: "Quantity omitted from supplier bill",
      lines: [ { document_line_id: @bill.document_lines.first.id, quantity: "0.5" } ]
    }
  end

  def api_note_params = note_params

  def invite_user(email, role_code)
    invitation = Onboarding::Invite.create!(
      tenant: @org.tenant, email: email, role_code: role_code, invited_by: @org.user
    )
    Onboarding::Invite.accept!(
      token: invitation.generate_token_for(:invite), password: "correct-horse-battery"
    )
  end
end
