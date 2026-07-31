# frozen_string_literal: true

require "test_helper"

class StageThreeMasterDataTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "stage-three-masters@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Stage Three Masters"
    )
    @entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
  end

  test "managed party changes roles and lifecycle through the audit chain" do
    party = assert_difference -> { LedgerEvent.for_tenant(@org.tenant.id).count }, 1 do
      Parties::Manage.create!(
        tenant: @org.tenant,
        attributes: {
          party_number: "c-001", name: "Acme Customer", email: "ACCOUNTS@ACME.EXAMPLE",
          state_code: "27", country_code: "in"
        },
        roles: %w[customer vendor],
        actor: @org.user
      )
    end
    assert_equal "C-001", party.party_number
    assert_equal "accounts@acme.example", party.email
    assert_equal %w[customer vendor], party.role_codes
    assert_equal "party.created", LedgerEvent.for_tenant(@org.tenant.id).in_order.last.action

    Parties::Manage.update!(
      party: party, attributes: { active: false }, roles: %w[customer], actor: @org.user
    )
    refute party.reload.active?
    assert_equal [ "customer" ], party.role_codes
    assert_equal "party.deactivated", LedgerEvent.for_tenant(@org.tenant.id).in_order.last.action
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]
  end

  test "a party needs at least one supported role" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      Parties::Manage.create!(
        tenant: @org.tenant,
        attributes: { party_number: "NONE", name: "No role" },
        roles: [],
        actor: @org.user
      )
    end
    assert_match(/roles/, error.message)
    refute Party.exists?(tenant_id: @org.tenant.id, party_number: "NONE")
  end

  test "entity registrations are effective-dated linked to an office and audited" do
    registration = TaxRegistrations::Manage.create!(
      tenant: @org.tenant,
      entity: @entity,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2026, 4, 1)
      },
      office_ids: [ @office.id ],
      actor: @org.user
    )

    assert_equal "27", registration.state_code
    assert_equal [ @office.id ], registration.office_ids
    assert_includes TaxRegistration.in_force_on(Date.new(2026, 7, 1)), registration
    assert_equal "tax_registration.created", LedgerEvent.for_tenant(@org.tenant.id).in_order.last.action

    successor = TaxRegistrations::Manage.create!(
      tenant: @org.tenant,
      entity: @entity,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2027, 4, 1)
      },
      office_ids: [ @office.id ],
      actor: @org.user
    )
    assert successor.persisted?, "the same GSTIN may have a new effective-dated master version"
  end

  test "registration validation rejects bad checksums and cross-tenant offices" do
    invalid = TaxRegistration.new(
      tenant_id: @org.tenant.id,
      entity: @entity,
      kind: "GSTIN",
      identifier: "27AAPFU0939F1ZZ",
      valid_from: Date.new(2026, 4, 1)
    )
    refute invalid.valid?
    assert_includes invalid.errors[:identifier], "is not a valid GSTIN"

    other = Onboarding::SignUp.call(
      email: "stage-three-other@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Other Masters"
    )
    other_office = Office.find_by!(tenant_id: other.tenant.id, code: "PRIMARY")
    error = assert_raises(ActiveRecord::RecordInvalid) do
      TaxRegistrations::Manage.create!(
        tenant: @org.tenant,
        entity: @entity,
        attributes: {
          kind: "GSTIN", identifier: "29AAAAA0300L1Z8", valid_from: Date.new(2026, 4, 1)
        },
        office_ids: [ other_office.id ],
        actor: @org.user
      )
    end
    assert_match(/office/, error.message)
  end

  test "party GSTINs derive state and respect effective dates" do
    party = Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: { party_number: "C-GST", name: "Registered Customer" },
      roles: %w[customer],
      actor: @org.user
    )
    registration = party.party_tax_registrations.create!(
      tenant_id: @org.tenant.id,
      kind: "GSTIN",
      identifier: "29AAAAA0300L1Z8",
      valid_from: Date.new(2026, 4, 1)
    )

    assert_equal "29", registration.state_code
    assert_includes party.party_tax_registrations.in_force_on(Date.new(2026, 7, 1)), registration

    error = assert_raises(ActiveRecord::RecordInvalid) do
      Parties::Manage.update!(
        party: party,
        attributes: { state_code: "27" },
        roles: party.role_codes,
        tax_registration_attributes: {
          kind: "GSTIN", identifier: "29AAAAA0300L1Z8", valid_from: Date.new(2026, 4, 1)
        },
        actor: @org.user
      )
    end
    assert_match(/must match the GSTIN state code 29/, error.message)
    assert_nil party.reload.state_code
  end

  test "managed service catalogue entries validate tax and account determination" do
    item = Items::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        code: "CONSULT", name: "Consulting services", item_type: "service",
        hsn_sac_code: "998311", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
        cess_rate_basis_points: 0, income_account_code: "4000", expense_account_code: "5000"
      },
      actor: @org.user
    )
    assert item.active?
    assert_equal "item.created", LedgerEvent.for_tenant(@org.tenant.id).in_order.last.action

    Items::Manage.update!(item: item, attributes: { active: false }, actor: @org.user)
    refute item.reload.active?
    assert_equal "item.deactivated", LedgerEvent.for_tenant(@org.tenant.id).in_order.last.action

    invalid = Item.new(
      tenant_id: @org.tenant.id, code: "BAD", name: "Bad service", item_type: "service",
      hsn_sac_code: "ABC", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
      income_account_code: "1000", expense_account_code: "4000"
    )
    refute invalid.valid?
    assert invalid.errors[:hsn_sac_code].any?
    assert invalid.errors[:income_account_code].any?
    assert invalid.errors[:expense_account_code].any?
  end
end
