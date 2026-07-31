# frozen_string_literal: true

require "test_helper"

class PurchaseBillFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "purchase-bill-flow@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Purchase Bill Flow"
    )
    @entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office.update!(
      address_line1: "1 Ledger Lane", city: "Mumbai", postal_code: "400001",
      state_code: "27", country_code: "IN"
    )
    @buyer_registration = TaxRegistrations::Manage.create!(
      tenant: @org.tenant,
      entity: @entity,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2026, 4, 1)
      },
      office_ids: [ @office.id ],
      actor: @org.user
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
    sign_in_as(@org.user)
  end

  test "owner records reviews and posts a purchase bill in the browser" do
    get new_purchase_bill_path
    assert_response :success
    assert_select "h1", "Record a purchase bill"
    assert_select "option", text: /Acme Vendor/
    assert_select "option", text: /27AAPFU0939F1ZV/
    assert_select "option", text: /Legal services/

    assert_difference -> { Document.where(tenant_id: @org.tenant.id, doc_type: "PB").count }, 1 do
      post purchase_bills_path, params: browser_bill_params
    end
    bill = Document.where(tenant_id: @org.tenant.id, doc_type: "PB").order(:id).last
    assert_redirected_to purchase_bill_path(bill, tenant_id: @org.tenant.id)

    follow_redirect!
    assert_response :success
    assert_select "h1", "Draft bill"
    assert_select "th", text: /IGST input credit/
    assert_select "td", text: /INR 118\.00/
    assert_select "button", text: "Post bill"

    post post_purchase_bill_path(bill)
    assert_redirected_to purchase_bill_path(bill, tenant_id: @org.tenant.id)
    assert_equal "posted", bill.reload.state
    assert_equal "PB/26-27/00001", bill.document_number
    assert_equal 3, Entry.find(bill.posted_entry_id).entry_lines.count

    get purchase_bills_path
    assert_response :success
    assert_select "td", text: /PB\/26-27\/00001/
    assert_select "td", text: /V-INV-001/
    assert_select "td", text: /Acme Vendor/
  end

  test "operator can create and post bills through the JSON API" do
    operator = invite_user("purchase-bill-operator@folio.invalid", "operator")
    sign_out
    sign_in_as(operator)

    assert Authorization.permits?(
      user: operator, tenant_id: @org.tenant.id, capability: "bills.create"
    )
    post "/api/v1/purchase_bills", params: api_bill_params
    assert_response :created
    json = JSON.parse(response.body).fetch("purchase_bill")
    assert_equal({ "igst" => 1_800 }, json.fetch("tax_breakdown"))
    assert_equal "V-INV-001", json.fetch("supplier_invoice_number")

    post "/api/v1/purchase_bills/#{json.fetch("id")}/post"
    assert_response :success
    posted = JSON.parse(response.body).fetch("purchase_bill")
    assert_equal "PB/26-27/00001", posted.fetch("document_number")
    entry = Entry.find(JSON.parse(response.body).fetch("entry_id"))
    assert_equal "operator", RoleTemplate.find(entry.role_template_id).code
  end

  test "viewer may inspect bills but cannot create them" do
    bill = PurchaseBills::BuildDraft.call(**builder_attributes)
    viewer = invite_user("purchase-bill-viewer@folio.invalid", "viewer")
    sign_out
    sign_in_as(viewer)

    get purchase_bills_path
    assert_response :success
    get purchase_bill_path(bill)
    assert_response :success
    get new_purchase_bill_path
    assert_redirected_to root_path(tenant_id: @org.tenant.id)

    assert_no_difference "Document.count" do
      post "/api/v1/purchase_bills", params: api_bill_params
    end
    assert_response :forbidden
  end

  test "duplicate supplier references return a recoverable API error and remain tenant scoped" do
    post "/api/v1/purchase_bills", params: api_bill_params
    assert_response :created
    bill_id = JSON.parse(response.body).dig("purchase_bill", "id")

    post "/api/v1/purchase_bills", params: api_bill_params.merge(external_reference: "v-inv-001")
    assert_response :unprocessable_entity
    assert_match(/already recorded/, JSON.parse(response.body).fetch("error"))

    other = Onboarding::SignUp.call(
      email: "purchase-bill-other@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Purchase Bill Other"
    )
    sign_out
    sign_in_as(other.user)
    get "/api/v1/purchase_bills/#{bill_id}"
    assert_response :not_found
  end

  private

  def browser_bill_params
    {
      purchase_bill: {
        party_id: @vendor.id,
        tax_registration_id: @buyer_registration.id,
        document_date: "2026-07-31",
        due_date: "2026-08-30",
        place_of_supply_state_code: "27",
        external_reference: "V-INV-001",
        narration: "July legal fees",
        lines: [ { item_id: @service.id, quantity: "2", unit_price: "50.00" } ]
      }
    }
  end

  def api_bill_params
    browser_bill_params.fetch(:purchase_bill)
  end

  def builder_attributes
    api_bill_params.merge(tenant: @org.tenant)
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
