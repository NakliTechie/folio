# frozen_string_literal: true

require "test_helper"

# B3.0 — the org spine, parties, ledgers, dimensions. These run in CI (regression
# cover on the new tables); the schema-assertion spec tests stay blanket-skipped as
# the debt record until B3.5.
class OrgSpineTest < ActiveSupport::TestCase
  test "an entity needs a 3-letter ISO currency and a known jurisdiction profile" do
    e = Entity.new(tenant_id: 1, code: "ACME", legal_name: "Acme Pvt Ltd",
                   functional_currency: "INR", fiscal_year_variant: "IN_APR_MAR",
                   jurisdiction_profile: "IN")
    assert e.valid?, e.errors.full_messages.join(", ")

    e.functional_currency = "RUPEE"
    assert_not e.valid?
    e.functional_currency = "INR"

    e.jurisdiction_profile = "ZZ"
    assert_not e.valid?, "jurisdiction profile must be one of IN/DE/UK/US/MY"
  end

  test "all five seeded jurisdiction profiles are accepted" do
    %w[IN DE UK US MY].each do |jp|
      e = Entity.new(tenant_id: 1, code: "E_#{jp}", legal_name: "x",
                     functional_currency: "USD", fiscal_year_variant: "CAL", jurisdiction_profile: jp)
      assert e.valid?, "#{jp} should be a valid profile"
    end
  end

  test "an office belongs to an entity and carries no GSTIN column" do
    assert_not Office.column_names.include?("has_own_gstin"),
      "GSTIN lives in tax_registrations, never as a boolean on offices"
    assert Office.reflect_on_association(:entity).present?
  end

  test "tax_registration.in_force_on respects effective dating" do
    e = Entity.create!(tenant_id: 1, code: "E1", legal_name: "x", functional_currency: "INR",
                       fiscal_year_variant: "IN_APR_MAR", jurisdiction_profile: "IN")
    old = TaxRegistration.create!(tenant_id: 1, entity_id: e.id, kind: "GSTIN",
                                  identifier: "27AAAAA0000A1Z5", valid_from: "2024-04-01",
                                  valid_to: "2025-03-31")
    cur = TaxRegistration.create!(tenant_id: 1, entity_id: e.id, kind: "GSTIN",
                                  identifier: "27AAAAA0000A1Z5", valid_from: "2025-04-01", valid_to: nil)

    on_date = TaxRegistration.in_force_on(Date.new(2025, 6, 1)).pluck(:id)
    assert_includes on_date, cur.id
    assert_not_includes on_date, old.id, "a superseded registration must not be in force later"
  end

  test "tax_registration kind is constrained" do
    reg = TaxRegistration.new(tenant_id: 1, entity_id: 1, kind: "PAN", identifier: "x")
    assert_not reg.valid?, "PAN is not a registration kind"
  end

  test "a party carries many roles" do
    p = Party.create!(tenant_id: 1, party_number: "V-001", name: "Supplier Co")
    p.party_roles.create!(role: "vendor")
    p.party_roles.create!(role: "customer")
    assert_equal %w[customer vendor], p.party_roles.pluck(:role).sort
  end

  test "a ledger kind is standard or extension" do
    l = Ledger.new(tenant_id: 1, code: "PRIMARY", name: "Primary", kind: "weird")
    assert_not l.valid?
    l.kind = "standard"
    assert l.valid?
  end

  test "a committed dimension is a real column marker; an uncommitted one lives in extra" do
    d = Dimension.create!(tenant_id: 1, code: "COST_CENTER", label: "Cost centre",
                          value_type: "reference", committed: true)
    assert d.committed
    d2 = Dimension.create!(tenant_id: 1, code: "CAMPAIGN", label: "Campaign",
                           value_type: "text", committed: false)
    assert_not d2.committed, "uncommitted dimensions belong in entry_lines.extra, never aggregated"
  end
end
