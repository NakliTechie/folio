# frozen_string_literal: true

require "test_helper"

class FixedAssetFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "assets-browser@folio.invalid", password: "correct-horse-battery",
      org_name: "Assets Browser"
    )
    @asset_class = AssetClass.find_by!(tenant_id: @org.tenant.id, code: "PPE")
    sign_in_as(@org.user)
  end

  test "owner creates and capitalizes a component then runs depreciation" do
    get fixed_assets_path
    assert_response :success
    assert_select "h1", "Fixed assets"

    assert_difference "AssetClass.count", 1 do
      post create_class_fixed_assets_path, params: {
        asset_class: {
          code: "IT", name: "IT equipment", default_useful_life_months: "36",
          apc_account_code: "1400", accumulated_depreciation_account_code: "1410",
          depreciation_expense_account_code: "5150", gain_account_code: "4200",
          loss_account_code: "5155"
        }
      }
    end
    it_class = AssetClass.find_by!(tenant_id: @org.tenant.id, code: "IT")

    assert_difference "FixedAsset.count", 1 do
      post fixed_assets_path, params: {
        fixed_asset: {
          asset_class_id: it_class.id, asset_number: "2000", component_number: "0001",
          name: "Server", capitalization_date: "2026-04-01", quantity: "1",
          unit_of_measure: "EA", book_useful_life_months: "12", book_residual_value: "0",
          book_depreciation_start_date: "2026-04-01", tax_useful_life_months: "12",
          tax_residual_value: "0", tax_depreciation_start_date: "2026-04-01"
        }
      }
    end
    asset = FixedAsset.find_by!(tenant_id: @org.tenant.id, asset_number: "2000")
    assert_redirected_to fixed_assets_path(tenant_id: @org.tenant.id)

    assert_difference "AssetTransaction.count", 2 do
      post acquire_fixed_asset_path(asset), params: {
        acquisition: {
          amount: "1200", offset_account_code: "3000", asset_value_date: "2026-04-01",
          posting_date: "2026-04-01", idempotency_key: "browser-acquire"
        }
      }
    end
    assert_redirected_to fixed_assets_path(tenant_id: @org.tenant.id)

    post run_depreciation_fixed_assets_path, params: {
      through_date: "2027-03-31", posting_date: "2027-03-31",
      mode: "post", idempotency_key: "browser-depreciation"
    }
    assert_redirected_to fixed_assets_path(tenant_id: @org.tenant.id)
    follow_redirect!
    assert_select "table", text: /2000-0001.*BOOK.*INR 1,200.00/m
    assert_select "table", text: /TAX_IT.*non-posting/m
  end

  test "viewer sees the asset history but no mutation forms" do
    viewer = invite_user("assets-viewer@folio.invalid", "viewer")
    sign_out
    sign_in_as(viewer)

    get fixed_assets_path
    assert_response :success
    assert_select "form[action='#{fixed_assets_path}']", count: 0
    assert_select "form[action='#{create_class_fixed_assets_path}']", count: 0
    assert_select "form[action='#{run_depreciation_fixed_assets_path}']", count: 0
    assert_no_difference "FixedAsset.count" do
      post fixed_assets_path, params: { fixed_asset: { asset_number: "NOPE" } }
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
