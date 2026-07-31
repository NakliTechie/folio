# frozen_string_literal: true

require "test_helper"

class StageThreeMasterFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "stage-three-browser@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Stage Three Browser"
    )
    @office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    sign_in_as(@org.user)
  end

  test "owner configures GST identity customer and service through browser flows" do
    get new_tax_registration_path
    assert_response :success
    assert_select "h1", "Add a tax registration"

    assert_difference "TaxRegistration.count", 1 do
      post tax_registrations_path, params: {
        tax_registration: {
          kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
          valid_from: "2026-04-01", office_ids: [ @office.id ]
        }
      }
    end
    assert_redirected_to tax_registrations_path(tenant_id: @org.tenant.id)

    assert_difference "Party.count", 1 do
      post parties_path, params: {
        party: {
          party_number: "C-001", name: "Acme Customer", roles: [ "customer" ],
          email: "accounts@acme.example", state_code: "29", country_code: "IN",
          tax_registration: {
            kind: "GSTIN", identifier: "29AAAAA0300L1Z8", valid_from: "2026-04-01"
          }
        }
      }
    end
    assert_redirected_to parties_path(tenant_id: @org.tenant.id)
    party = Party.find_by!(tenant_id: @org.tenant.id, party_number: "C-001")
    assert_equal [ "customer" ], party.role_codes
    assert_equal "29", party.party_tax_registrations.first.state_code

    assert_difference "Item.count", 1 do
      post items_path, params: {
        item: {
          code: "CONSULT", name: "Consulting services", item_type: "service",
          hsn_sac_code: "998311", unit_of_measure: "OTH", tax_rate: "18.00", cess_rate: "0",
          income_account_code: "4000", expense_account_code: "5000"
        }
      }
    end
    assert_redirected_to items_path(tenant_id: @org.tenant.id)
    item = Item.find_by!(tenant_id: @org.tenant.id, code: "CONSULT")
    assert_equal 1800, item.tax_rate_basis_points

    get parties_path
    assert_response :success
    assert_select "td", text: /29AAAAA0300L1Z8/
    get items_path
    assert_response :success
    assert_select "td", text: /18%/
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]
  end

  test "browser forms return recoverable errors for invalid statutory data" do
    assert_no_difference "Party.count" do
      post parties_path, params: {
        party: {
          party_number: "C-BAD", name: "Bad GSTIN", roles: [ "customer" ], country_code: "IN",
          tax_registration: {
            kind: "GSTIN", identifier: "27AAPFU0939F1ZZ", valid_from: "2026-04-01"
          }
        }
      }
    end
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /valid GSTIN/

    assert_no_difference "Item.count" do
      post items_path, params: {
        item: {
          code: "BAD", name: "Bad service", item_type: "service", hsn_sac_code: "ABC",
          unit_of_measure: "OTH", tax_rate: "18.555", cess_rate: "0",
          income_account_code: "4000", expense_account_code: "5000"
        }
      }
    end
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /valid percentages/
  end

  test "viewer can inspect parties and catalogue but cannot mutate masters or enter tax setup" do
    viewer = Onboarding::Invite.accept!(
      token: Onboarding::Invite.create!(
        tenant: @org.tenant, email: "stage-three-viewer@folio.invalid",
        role_code: "viewer", invited_by: @org.user
      ).generate_token_for(:invite),
      password: "correct-horse-battery"
    )
    sign_out
    sign_in_as(viewer)

    get parties_path
    assert_response :success
    get items_path
    assert_response :success
    get tax_registrations_path
    assert_redirected_to root_path(tenant_id: @org.tenant.id)

    assert_no_difference "Party.count" do
      post parties_path, params: {
        party: { party_number: "NO", name: "Forbidden", roles: [ "customer" ], country_code: "IN" }
      }
    end
    assert_redirected_to root_path(tenant_id: @org.tenant.id)
  end

  test "JSON masters are tenant scoped capability guarded and include frozen tax inputs" do
    post "/api/v1/parties", params: {
      party_number: "C-API", name: "API Customer", roles: [ "customer" ], state_code: "29",
      country_code: "IN",
      tax_registration: {
        kind: "GSTIN", identifier: "29AAAAA0300L1Z8", valid_from: "2026-04-01"
      }
    }
    assert_response :created
    party_json = JSON.parse(response.body).fetch("party")
    assert_equal "29", party_json.dig("tax_registration", "state_code")
    party_id = party_json.fetch("id")

    post "/api/v1/items", params: {
      code: "API-SVC", name: "API service", item_type: "service", hsn_sac_code: "998311",
      unit_of_measure: "OTH", tax_rate_basis_points: 1800, cess_rate_basis_points: 0,
      income_account_code: "4000", expense_account_code: "5000"
    }
    assert_response :created
    assert_equal 1800, JSON.parse(response.body).dig("item", "tax_rate_basis_points")

    post "/api/v1/tax_registrations", params: {
      kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
      valid_from: "2026-04-01", office_ids: [ @office.id ]
    }
    assert_response :created
    assert_equal [ @office.id ], JSON.parse(response.body).dig("tax_registration", "office_ids")

    other = Onboarding::SignUp.call(
      email: "stage-three-api-other@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Stage Three API Other"
    )
    sign_out
    sign_in_as(other.user)
    get "/api/v1/parties/#{party_id}"
    assert_response :not_found

    operator = Onboarding::Invite.accept!(
      token: Onboarding::Invite.create!(
        tenant: other.tenant, email: "stage-three-operator@folio.invalid",
        role_code: "operator", invited_by: other.user
      ).generate_token_for(:invite),
      password: "correct-horse-battery"
    )
    sign_out
    sign_in_as(operator)
    assert_no_difference "Item.count" do
      post "/api/v1/items", params: {
        code: "NO", name: "Forbidden", item_type: "service", hsn_sac_code: "998311",
        unit_of_measure: "OTH", tax_rate_basis_points: 1800,
        income_account_code: "4000", expense_account_code: "5000"
      }
    end
    assert_response :forbidden
  end
end
