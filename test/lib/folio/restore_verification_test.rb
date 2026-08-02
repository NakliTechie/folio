# frozen_string_literal: true

require "test_helper"

class Folio::RestoreVerificationTest < ActiveSupport::TestCase
  test "checks both chains and every entity trial balance for every tenant" do
    org = Onboarding::SignUp.call(
      email: "restore-verification@folio.invalid", password: "correct-horse-battery",
      org_name: "Restore Verification"
    )
    result = Folio::RestoreVerification.call
    tenant = result.fetch(:tenants).find { |row| row.fetch(:tenant_id) == org.tenant.id }

    assert_equal "ok", result.fetch(:status)
    assert tenant
    assert_equal tenant.fetch(:ledger_rows), LedgerEvent.for_tenant(org.tenant.id).count
    assert_equal tenant.fetch(:domain_rows), DomainEvent.for_tenant(org.tenant.id).count
    assert tenant.fetch(:entities).all? { |entity| entity.fetch(:debit_minor) == entity.fetch(:credit_minor) }
  end
end
