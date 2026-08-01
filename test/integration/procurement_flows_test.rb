# frozen_string_literal: true

require "test_helper"

class ProcurementFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "procurement-browser@folio.invalid", password: "correct-horse-battery",
      org_name: "Procurement Browser"
    )
    @vendor = Parties::Manage.create!(
      tenant: @org.tenant, actor: @org.user,
      attributes: {
        party_number: "V-BROWSER", name: "Browser Supplies", state_code: "27", country_code: "IN",
        address_line1: "2 Supply Road", city: "Mumbai", postal_code: "400002"
      },
      roles: [ "vendor" ]
    )
    @item = Items::Manage.create!(
      tenant: @org.tenant, actor: @org.user,
      attributes: {
        code: "BOLT", name: "Bolt", item_type: "good", hsn_sac_code: "7318",
        unit_of_measure: "NOS", tax_rate_basis_points: 1800, cess_rate_basis_points: 0,
        income_account_code: "4000", expense_account_code: "5000",
        inventory_class: "raw_material", revision: "A", valuation_method: "moving_average",
        inventory_account_code: "1300"
      }
    )
    @warehouse = Warehouse.find_by!(tenant_id: @org.tenant.id, code: "MAIN")
    @checker = invite_user("procurement-browser-checker@folio.invalid", "accountant")
    sign_in_as(@org.user)
  end

  test "browser completes vendor approval purchase-order approval and goods receipt" do
    get procurement_path
    assert_response :success
    assert_select "h1", "Procurement"
    assert_select "option", text: /Browser Supplies/

    post onboard_vendor_procurement_path, params: {
      vendor_profile: {
        party_id: @vendor.id, payment_terms_days: 15, preferred_currency: "INR"
      }
    }
    profile = VendorProfile.find_by!(tenant_id: @org.tenant.id, party_id: @vendor.id)
    assert_redirected_to procurement_path(tenant_id: @org.tenant.id)

    sign_out
    sign_in_as(@checker)
    post approve_vendor_procurement_path, params: { id: profile.id }
    assert_equal "approved", profile.reload.status

    sign_out
    sign_in_as(@org.user)
    post create_order_procurement_path, params: {
      purchase_order: {
        vendor_profile_id: profile.id, order_date: "2026-08-01", expected_on: "2026-08-08",
        description: "Production fasteners",
        lines: [ { item_id: @item.id, warehouse_id: @warehouse.id, quantity: "25", unit_price: "4" } ]
      }
    }
    order = PurchaseOrder.find_by!(tenant_id: @org.tenant.id)
    assert_equal "draft", order.status

    sign_out
    sign_in_as(@checker)
    post approve_order_procurement_path, params: { id: order.id }
    assert_equal "approved", order.reload.status

    sign_out
    sign_in_as(@org.user)
    assert_difference "GoodsReceipt.count", 1 do
      post receive_order_procurement_path, params: {
        id: order.id,
        goods_receipt: {
          received_on: "2026-08-01", external_reference: "DN-BROWSER",
          idempotency_key: "browser-goods-receipt",
          lines: [ { purchase_order_line_id: order.purchase_order_lines.sole.id, quantity: "25" } ]
        }
      }
    end
    assert_redirected_to procurement_path(tenant_id: @org.tenant.id)
    follow_redirect!
    assert_select "table", text: /PO\/2026-27\/00001.*Browser Supplies.*Received/m
    assert_select "table", text: /25\.0 \/ 25\.0 NOS/
  end

  test "viewer sees evidence but no procurement mutation forms" do
    profile = Procurement::ManageVendor.onboard!(
      tenant: @org.tenant, actor: @org.user,
      attributes: { party_id: @vendor.id, payment_terms_days: 30, preferred_currency: "INR" }
    )
    viewer = invite_user("procurement-browser-viewer@folio.invalid", "viewer")
    sign_out
    sign_in_as(viewer)

    get procurement_path
    assert_response :success
    assert_select "table", text: /Browser Supplies.*Pending/m
    %w[onboard_vendor create_order approve_vendor receive_order].each do |action|
      assert_select "form[action='#{public_send("#{action}_procurement_path")}']", count: 0
    end
    assert_no_difference "PurchaseOrder.count" do
      post create_order_procurement_path, params: { purchase_order: { vendor_profile_id: profile.id } }
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
