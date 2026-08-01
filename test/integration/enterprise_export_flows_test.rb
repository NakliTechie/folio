# frozen_string_literal: true

require "test_helper"
require "stringio"
require "zip"

class EnterpriseExportFlowsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Onboarding::SignUp.call(
      email: "sap-export-browser@folio.invalid", password: "correct-horse-battery",
      org_name: "SAP Export Browser"
    )
    @entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    sign_in_as(@org.user)
  end

  test "owner downloads a scoped DTW package in the browser" do
    get enterprise_export_path
    assert_response :success
    assert_select "h1", "Enterprise exports"
    assert_select "form[action='#{sap_b1_dtw_enterprise_export_path}']"

    get sap_b1_dtw_enterprise_export_path, params: {
      scope: "entity", entity_id: @entity.id,
      from_date: "2026-08-01", to_date: "2026-08-31"
    }
    assert_response :success
    assert_equal "application/zip", response.media_type
    assert_match(/folio-sap-b1-dtw-entity-primary/, response.headers.fetch("Content-Disposition"))
    Zip::File.open_buffer(StringIO.new(response.body)) do |archive|
      assert archive.find_entry("FOLIO-MANIFEST.json")
    end
  end

  test "viewer cannot see or call the export surface" do
    viewer = invite_user("sap-export-viewer@folio.invalid", "viewer")
    sign_out
    sign_in_as(viewer)
    get enterprise_export_path
    assert_redirected_to root_path(tenant_id: @org.tenant.id)
    get sap_b1_dtw_enterprise_export_path, params: {
      scope: "entity", entity_id: @entity.id,
      from_date: "2026-08-01", to_date: "2026-08-31"
    }
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
