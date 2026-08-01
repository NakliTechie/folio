# frozen_string_literal: true

require "test_helper"

class SettlementFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "settlement-flow@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Settlement Flow"
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
    customer = create_party("C-001", "Acme Customer", "customer", "27AAPFU0939F1ZV", "27")
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
      tenant: @org.tenant, party_id: customer.id, tax_registration_id: registration.id,
      document_date: Date.new(2026, 7, 31), due_date: Date.new(2026, 8, 30),
      place_of_supply_state_code: "27",
      lines: [ { item_id: service.id, quantity: "2", unit_price: "50.00" } ]
    )
    Documents::Post.call(invoice, actor: "u:#{@org.user.id}")
    bill = PurchaseBills::BuildDraft.call(
      tenant: @org.tenant, party_id: vendor.id, tax_registration_id: registration.id,
      document_date: Date.new(2026, 7, 31), due_date: Date.new(2026, 8, 30),
      place_of_supply_state_code: "27", external_reference: "V-INV-001",
      place_of_supply_override_reason: "Supplier invoice records Maharashtra as the place of supply",
      actor: @org.user,
      lines: [ { item_id: service.id, quantity: "2", unit_price: "50.00" } ]
    )
    Documents::Post.call(bill, actor: "u:#{@org.user.id}")
    @receivable = open_item(invoice, "1200")
    @payable = open_item(bill, "2000")
    sign_in_as(@org.user)
  end

  test "owner reviews and posts a partial customer receipt in the browser" do
    get new_settlement_path(kind: "receipt")
    assert_response :success
    assert_select "h1", "Record a customer receipt"
    assert_select "td", text: /SI\/26-27\/00001/
    assert_select "td", text: /Acme Customer/

    assert_difference -> { Document.where(tenant_id: @org.tenant.id, doc_type: "RC").count }, 1 do
      post settlements_path, params: browser_receipt_params
    end
    receipt = Document.where(tenant_id: @org.tenant.id, doc_type: "RC").order(:id).last
    assert_redirected_to settlement_path(receipt, tenant_id: @org.tenant.id)

    follow_redirect!
    assert_response :success
    assert_select "h1", "Draft customer receipt"
    assert_select "td", text: /Preserve original ageing/
    assert_select "button", text: "Post customer receipt"

    post post_settlement_path(receipt)
    assert_redirected_to settlement_path(receipt, tenant_id: @org.tenant.id)
    assert_equal "RC/26-27/00001", receipt.reload.document_number
    assert_equal 7_800, Posting::Clearing.open_amount(stable_target(@receivable))

    get settlements_path
    assert_response :success
    assert_select "td", text: /RC\/26-27\/00001/
    assert_select "td", text: /Customer receipt/
  end

  test "operator posts a full vendor payment through the JSON API" do
    operator = invite_user("settlement-operator@folio.invalid", "operator")
    sign_out
    sign_in_as(operator)

    post "/api/v1/settlements", params: api_payment_params
    assert_response :created
    json = JSON.parse(response.body).fetch("settlement")
    assert_equal "payment", json.fetch("kind")
    assert_equal 11_800, json.fetch("total_minor")
    assert_equal "2000", json.dig("allocations", 0, "target", "accountCode")

    post "/api/v1/settlements/#{json.fetch("id")}/post"
    assert_response :success
    posted = JSON.parse(response.body).fetch("settlement")
    assert_equal "PY/26-27/00001", posted.fetch("document_number")
    assert_equal "applied", posted.dig("allocations", 0, "status")
    assert_equal 0, Posting::Clearing.open_amount(stable_target(@payable))

    allocation_id = posted.dig("allocations", 0, "id")
    post "/api/v1/settlements/#{json.fetch("id")}/allocations/#{allocation_id}/reset"
    assert_response :success
    assert_equal "unapplied", JSON.parse(response.body).dig("allocation", "status")
    assert_equal 11_800, Posting::Clearing.open_amount(stable_target(@payable))

    post "/api/v1/settlements/#{json.fetch("id")}/allocations/#{allocation_id}/reallocate", params: {
      target_entry_line_id: stable_target(@payable).id,
      clearing_mode: "partial"
    }
    assert_response :success
    assert_equal 0, Posting::Clearing.open_amount(stable_target(@payable))
  end

  test "viewer can inspect settlements but cannot create them" do
    receipt = Settlements::BuildDraft.call(**receipt_builder_attributes)
    viewer = invite_user("settlement-viewer@folio.invalid", "viewer")
    sign_out
    sign_in_as(viewer)

    get settlements_path
    assert_response :success
    get settlement_path(receipt)
    assert_response :success
    get new_settlement_path(kind: "receipt")
    assert_redirected_to root_path(tenant_id: @org.tenant.id)

    assert_no_difference "Document.count" do
      post "/api/v1/settlements", params: api_payment_params
    end
    assert_response :forbidden
  end

  test "settlement API is tenant scoped and malformed allocations are recoverable" do
    post "/api/v1/settlements", params: api_payment_params.merge(allocations: {})
    assert_response :unprocessable_entity
    assert_match(/allocations must be an array/, JSON.parse(response.body).fetch("error"))

    receipt = Settlements::BuildDraft.call(**receipt_builder_attributes)
    other = Onboarding::SignUp.call(
      email: "settlement-other@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Settlement Other"
    )
    sign_out
    sign_in_as(other.user)
    get "/api/v1/settlements/#{receipt.id}"
    assert_response :not_found
  end

  test "owner resets and reallocates a receipt through the correction UI" do
    receipt = Settlements::BuildDraft.call(**receipt_builder_attributes)
    Documents::Post.call(receipt, actor: "u:#{@org.user.id}")
    allocation = receipt.document_allocations.first

    post reset_settlement_allocation_path(receipt, allocation_id: allocation.id)
    assert_redirected_to settlement_path(receipt, tenant_id: @org.tenant.id)
    assert allocation.reload.reset?
    assert_equal 11_800, Posting::Clearing.open_amount(allocation.target_item)

    get new_settlement_reallocation_path(receipt, allocation_id: allocation.id)
    assert_response :success
    assert_select "h1", "Reallocate unapplied cash"
    assert_select "option", text: /SI\/26-27\/00001/

    post settlement_reallocation_path(receipt, allocation_id: allocation.id), params: {
      reallocation: {
        target_entry_line_id: allocation.target_item.id,
        clearing_mode: "partial"
      }
    }
    assert_redirected_to settlement_path(receipt, tenant_id: @org.tenant.id)
    assert allocation.reload.settlement_reallocation
    assert_equal 7_800, Posting::Clearing.open_amount(allocation.settlement_reallocation.target_item)
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

  def open_item(document, account_code)
    EntryLine.joins(:entry).find_by!(entries: { document_id: document.id }, account_code: account_code)
  end

  def stable_target(item)
    EntryLine.find_by!(
      tenant_id: item.tenant_id,
      source_event_id: item.source_event_id,
      line_no: item.line_no
    )
  end

  def browser_receipt_params
    {
      settlement: {
        kind: "receipt",
        document_date: "2026-08-15",
        bank_account_code: "1010",
        narration: "NEFT receipt",
        allocations: [
          { target_entry_line_id: @receivable.id, amount: "40.00", clearing_mode: "partial" }
        ]
      }
    }
  end

  def api_payment_params
    {
      kind: "payment",
      document_date: "2026-08-15",
      bank_account_code: "1010",
      narration: "NEFT payment",
      allocations: [
        { target_entry_line_id: @payable.id, amount: "118.00", clearing_mode: "partial" }
      ]
    }
  end

  def receipt_builder_attributes
    {
      tenant: @org.tenant,
      doc_type: "RC",
      document_date: Date.new(2026, 8, 15),
      bank_account_code: "1010",
      allocations: [
        { target_entry_line_id: @receivable.id, amount: "40.00", clearing_mode: "partial" }
      ]
    }
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
