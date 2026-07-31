# frozen_string_literal: true

require "test_helper"

class PeriodControlsTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "period-controls-model@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Period Controls Model"
    )
  end

  test "state changes are validated, idempotent, and hash-chain audited" do
    before = LedgerEvent.for_tenant(@org.tenant.id).count
    control = PeriodControls::Manage.call(
      tenant: @org.tenant, fiscal_year: 2026, period_no: 4,
      state: "restricted", actor: @org.user
    )
    assert_equal "restricted", control.state
    assert_equal "period.lock", control.capability
    event = LedgerEvent.for_tenant(@org.tenant.id).last
    assert_equal "period.restricted", event.action
    assert_equal 2026, JSON.parse(event.payload).dig("periodControl", "fiscalYear")
    assert_equal before + 1, LedgerEvent.for_tenant(@org.tenant.id).count

    PeriodControls::Manage.call(
      tenant: @org.tenant, fiscal_year: 2026, period_no: 4,
      state: "restricted", actor: @org.user
    )
    assert_equal before + 1, LedgerEvent.for_tenant(@org.tenant.id).count

    control = PeriodControls::Manage.call(
      tenant: @org.tenant, fiscal_year: 2026, period_no: 4,
      state: "closed", actor: @org.user
    )
    assert_equal "closed", control.state
    assert_nil control.capability
    assert LedgerEvent.verify_chain(@org.tenant.id).fetch(:ok)
  end

  test "default open is not persisted and invalid controls fail closed" do
    control = PeriodControls::Manage.call(
      tenant: @org.tenant, fiscal_year: 2026, period_no: 4,
      state: "open", actor: @org.user
    )
    refute control.persisted?
    assert_equal "open", control.state
    assert_raises(PeriodControls::InvalidControl) do
      PeriodControls::Manage.call(
        tenant: @org.tenant, fiscal_year: 2026, period_no: 17,
        state: "closed", actor: @org.user
      )
    end

    outsider = Onboarding::SignUp.call(
      email: "period-control-outsider@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Period Control Outsider"
    )
    assert_raises(PeriodControls::InvalidControl) do
      PeriodControls::Manage.call(
        tenant: @org.tenant, fiscal_year: 2026, period_no: 4,
        state: "closed", actor: outsider.user
      )
    end
  end

  test "calendar maps India regular and special periods without inventing dates for period zero" do
    entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    assert_nil PeriodControls::Calendar.date_range(entity: entity, fiscal_year: 2026, period_no: 0)
    assert_equal Date.new(2026, 4, 1)..Date.new(2026, 4, 30),
      PeriodControls::Calendar.date_range(entity: entity, fiscal_year: 2026, period_no: 1)
    assert_equal Date.new(2027, 3, 1)..Date.new(2027, 3, 31),
      PeriodControls::Calendar.date_range(entity: entity, fiscal_year: 2026, period_no: 16)
  end
end
