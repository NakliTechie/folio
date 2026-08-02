# frozen_string_literal: true

require "test_helper"

class MfaFlowTest < ActionDispatch::IntegrationTest
  PASSWORD = "correct-horse-battery"

  setup do
    @org = Onboarding::SignUp.call(
      email: "mfa-#{name.parameterize}@folio.invalid", password: PASSWORD, org_name: "MFA Books"
    )
  end

  test "an authenticated user enrolls TOTP and receives recovery codes once" do
    sign_in_as(@org.user)
    post mfa_setup_security_path, params: { tenant_id: @org.tenant.id }
    assert_response :success
    secret = css_select(".account-code").first.text.delete(" ")
    code = Mfa::Totp.code(secret)

    post enable_mfa_security_path, params: {
      tenant_id: @org.tenant.id, password: PASSWORD, code: code
    }

    assert_response :success
    assert_select "h1", "Multi-factor authentication enabled"
    assert_select ".recovery-code-list li", 10
    assert @org.user.reload.mfa_enabled?
    refute_equal secret, @org.user.mfa_secret_ciphertext
    assert_equal secret, @org.user.mfa_secret
    assert Current.session.reload.mfa_verified_at
  end

  test "an enrolled user completes password plus TOTP login" do
    enable_mfa!

    post session_path, params: { email_address: @org.user.email_address, password: PASSWORD }
    assert_redirected_to new_mfa_session_path
    assert_predicate cookies[:session_id], :blank?

    post mfa_session_path, params: { code: "000000" }
    assert_redirected_to new_mfa_session_path
    assert_nil cookies[:session_id]

    post mfa_session_path, params: { code: Mfa::Totp.code(@org.user.mfa_secret) }
    assert_redirected_to root_path
    assert cookies[:session_id]
    assert @org.user.sessions.order(:id).last.mfa_verified_at
  end

  test "a recovery code signs in once and cannot be reused" do
    recovery_codes = enable_mfa!

    post session_path, params: { email_address: @org.user.email_address, password: PASSWORD }
    post mfa_session_path, params: { code: recovery_codes.first }
    assert_redirected_to root_path
    assert_equal 9, @org.user.reload.mfa_recovery_code_digests.size

    delete session_path
    post session_path, params: { email_address: @org.user.email_address, password: PASSWORD }
    post mfa_session_path, params: { code: recovery_codes.first }
    assert_redirected_to new_mfa_session_path
    assert_predicate cookies[:session_id], :blank?
  end

  test "the production MFA gate blocks mutations until enrollment" do
    sign_in_as(@org.user)
    previous = Rails.application.config.x.mfa_required
    Rails.application.config.x.mfa_required = true
    begin
      post invitations_path, params: {
        tenant_id: @org.tenant.id, email: "blocked@folio.invalid", role_code: "viewer"
      }
      assert_redirected_to security_path(tenant_id: @org.tenant.id)
      assert_equal 0, Invitation.where(tenant_id: @org.tenant.id).count

      post mfa_setup_security_path, params: { tenant_id: @org.tenant.id }
      assert_response :success
    ensure
      Rails.application.config.x.mfa_required = previous
    end
  end

  private

  def enable_mfa!
    codes = Mfa::RecoveryCodes.generate
    @org.user.enable_mfa!(secret: Mfa::Totp.generate_secret, recovery_codes: codes)
    codes
  end
end
