# frozen_string_literal: true

require "test_helper"

class InventoryFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "inventory-browser@folio.invalid", password: "correct-horse-battery",
      org_name: "Inventory Browser"
    )
    @item = Items::Manage.create!(
      tenant: @org.tenant, actor: @org.user,
      attributes: {
        code: "STEEL", name: "Steel", item_type: "good", hsn_sac_code: "7208",
        unit_of_measure: "KGS", tax_rate_basis_points: 1800, cess_rate_basis_points: 0,
        income_account_code: "4000", expense_account_code: "5000",
        inventory_class: "raw_material", revision: "A", valuation_method: "moving_average",
        inventory_account_code: "1300"
      }
    )
    @warehouse = Warehouse.find_by!(tenant_id: @org.tenant.id, code: "MAIN")
    sign_in_as(@org.user)
  end

  test "owner posts a receipt and sees valued on-hand inventory" do
    get inventory_path
    assert_response :success
    assert_select "h1", "Inventory"

    assert_difference "InventoryTransaction.count", 1 do
      post inventory_path, params: {
        inventory_movement: {
          transaction_type: "receipt", posting_date: "2026-08-01", item_id: @item.id,
          quantity: "2.5", unit_cost: "40", destination_warehouse_id: @warehouse.id,
          offset_account_code: "3000", external_reference: "GRN-1",
          reason: "Initial receipt", idempotency_key: "browser-receipt"
        }
      }
    end
    assert_redirected_to inventory_path(tenant_id: @org.tenant.id)
    follow_redirect!
    assert_select "table", text: /2.5.*KGS/
    assert_select "table", text: /INR 100.00/
  end

  test "viewer can inspect inventory but cannot post or create warehouses" do
    viewer = invite_user("inventory-viewer@folio.invalid", "viewer")
    sign_out
    sign_in_as(viewer)

    get inventory_path
    assert_response :success
    assert_select "form[action='#{inventory_path}']", count: 0
    assert_select "form[action='#{create_warehouse_inventory_path}']", count: 0
    assert_no_difference "InventoryTransaction.count" do
      post inventory_path, params: { inventory_movement: { transaction_type: "receipt" } }
    end
    assert_redirected_to root_path(tenant_id: @org.tenant.id)
  end

  private

  def invite_user(email, role_code)
    invitation = Onboarding::Invite.create!(
      tenant: @org.tenant, email: email, role_code: role_code, invited_by: @org.user
    )
    Onboarding::Invite.accept!(
      token: invitation.generate_token_for(:invite), password: "correct-horse-battery"
    )
  end
end
