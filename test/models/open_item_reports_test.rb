# frozen_string_literal: true

require "test_helper"

class OpenItemReportsTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "open-item-reports@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Open Item Reports"
    )
    entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    office.update!(
      address_line1: "1 Ledger Lane", city: "Mumbai", postal_code: "400001",
      state_code: "27", country_code: "IN"
    )
    registration = TaxRegistrations::Manage.create!(
      tenant: @org.tenant, entity: entity,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2026, 4, 1)
      },
      office_ids: [ office.id ], actor: @org.user
    )
    @customer = create_party("C-001", "Acme Customer", "customer", "27AAPFU0939F1ZV", "27")
    @vendor = create_party("V-001", "Acme Vendor", "vendor", "29AAAAA0300L1Z8", "29")
    service = Items::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        code: "CONSULT", name: "Consulting services", item_type: "service",
        hsn_sac_code: "998311", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
        cess_rate_basis_points: 0, income_account_code: "4000", expense_account_code: "5000"
      },
      actor: @org.user
    )
    @invoice = SalesInvoices::BuildDraft.call(
      tenant: @org.tenant, party_id: @customer.id, tax_registration_id: registration.id,
      document_date: Date.new(2026, 7, 31), due_date: Date.new(2026, 8, 30),
      place_of_supply_state_code: "27",
      lines: [ { item_id: service.id, quantity: "2", unit_price: "50.00" } ]
    )
    Documents::Post.call(@invoice, actor: "u:#{@org.user.id}")
    @bill = PurchaseBills::BuildDraft.call(
      tenant: @org.tenant, party_id: @vendor.id, tax_registration_id: registration.id,
      document_date: Date.new(2026, 7, 31), due_date: Date.new(2026, 8, 30),
      place_of_supply_state_code: "27", external_reference: "V-INV-001",
      place_of_supply_override_reason: "Supplier invoice identifies the Maharashtra recipient location",
      actor: @org.user,
      lines: [ { item_id: service.id, quantity: "2", unit_price: "50.00" } ]
    )
    Documents::Post.call(@bill, actor: "u:#{@org.user.id}")
  end

  test "aged reports separate current customer and vendor open items into stable buckets" do
    aged_to = Date.new(2026, 9, 30)
    receivables = Reports.aged_open_items(@org.tenant.id, role: "customer", aged_to: aged_to)
    payables = Reports.aged_open_items(@org.tenant.id, role: "vendor", aged_to: aged_to)

    assert_equal "current_open_items", receivables.fetch(:basis)
    assert_equal 11_800, receivables.fetch(:total_minor)
    assert_equal 11_800, receivables.dig(:totals, "days_61_90")
    assert_equal "SI/26-27/00001", receivables.dig(:rows, 0, :source_document_number)
    assert_equal 61, receivables.dig(:rows, 0, :age_days)

    assert_equal 11_800, payables.fetch(:total_minor)
    assert_equal 11_800, payables.dig(:totals, "days_61_90")
    assert_equal "PB/26-27/00001", payables.dig(:rows, 0, :source_document_number)
    assert_equal "Acme Vendor", payables.dig(:rows, 0, :party_name)
  end

  test "partial allocation preserves ageing and party ledger running balance" do
    receipt = build_receipt(mode: "partial")
    Documents::Post.call(receipt, actor: "u:#{@org.user.id}")

    report = Reports.aged_open_items(
      @org.tenant.id, role: "customer", aged_to: Date.new(2026, 9, 30)
    )
    assert_equal 7_800, report.fetch(:total_minor)
    assert_equal 61, report.dig(:rows, 0, :age_days)
    assert_equal "days_61_90", report.dig(:rows, 0, :bucket)

    ledger = Reports.party_ledger(@org.tenant.id, party_id: @customer.id)
    assert_equal "C-001", ledger.dig(:party, :party_number)
    assert_equal [ 11_800, 0 ], ledger.fetch(:rows).map { |row| row.fetch(:debit_minor) }
    assert_equal [ 0, 4_000 ], ledger.fetch(:rows).map { |row| row.fetch(:credit_minor) }
    assert_equal [ 11_800, 7_800 ], ledger.fetch(:rows).map { |row| row.fetch(:running_balance_minor) }
    assert_equal 7_800, ledger.fetch(:balance_minor)
    assert_equal 7_800, ledger.fetch(:open_minor)
  end

  test "residual allocation re-baselines the open balance into a younger bucket" do
    receipt = build_receipt(mode: "residual")
    Documents::Post.call(receipt, actor: "u:#{@org.user.id}")

    report = Reports.aged_open_items(
      @org.tenant.id, role: "customer", aged_to: Date.new(2026, 9, 30)
    )
    assert_equal 7_800, report.fetch(:total_minor)
    assert_equal 46, report.dig(:rows, 0, :age_days)
    assert_equal "days_31_60", report.dig(:rows, 0, :bucket)

    ledger = Reports.party_ledger(@org.tenant.id, party_id: @customer.id)
    assert_equal [ 11_800, 0, 0 ], ledger.fetch(:rows).map { |row| row.fetch(:debit_minor) }
    assert_equal [ 0, 4_000, 0 ], ledger.fetch(:rows).map { |row| row.fetch(:credit_minor) }
    assert_equal [ 11_800, 7_800, 7_800 ], ledger.fetch(:rows).map { |row| row.fetch(:running_balance_minor) }
    assert_equal 7_800, ledger.fetch(:balance_minor)
    assert_equal 7_800, ledger.fetch(:open_minor)
  end

  test "party ledgers remain tenant scoped" do
    other = Onboarding::SignUp.call(
      email: "open-item-reports-other@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Open Item Reports Other"
    )

    assert_raises(ActiveRecord::RecordNotFound) do
      Reports.party_ledger(other.tenant.id, party_id: @customer.id)
    end
  end

  private

  def create_party(number, name, role, gstin, state)
    Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        party_number: number, name: name, state_code: state, country_code: "IN",
        address_line1: "2 Party Road", city: state == "27" ? "Mumbai" : "Bengaluru",
        postal_code: state == "27" ? "400002" : "560002"
      },
      roles: [ role ],
      tax_registration_attributes: {
        kind: "GSTIN", identifier: gstin, valid_from: Date.new(2026, 4, 1)
      },
      actor: @org.user
    )
  end

  def build_receipt(mode:)
    target = EntryLine.joins(:entry).find_by!(
      entries: { document_id: @invoice.id }, account_code: "1200"
    )
    Settlements::BuildDraft.call(
      tenant: @org.tenant, doc_type: "RC", document_date: Date.new(2026, 8, 15),
      bank_account_code: "1010",
      allocations: [
        { target_entry_line_id: target.id, amount: "40.00", clearing_mode: mode }
      ]
    )
  end
end
