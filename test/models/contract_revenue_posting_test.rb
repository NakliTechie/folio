# frozen_string_literal: true

require "test_helper"

class ContractRevenuePostingTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "revenue-posting@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Revenue Posting"
    )
    @entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office.update!(
      address_line1: "1 Ledger Lane", city: "Mumbai", postal_code: "400001",
      state_code: "27", country_code: "IN"
    )
    @seller_registration = TaxRegistrations::Manage.create!(
      tenant: @org.tenant, entity: @entity,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2026, 4, 1)
      },
      office_ids: [ @office.id ], actor: @org.user
    )
    @customer = Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        party_number: "C-RRP", name: "Recognition Customer", state_code: "27", country_code: "IN",
        address_line1: "2 Customer Road", city: "Mumbai", postal_code: "400002"
      },
      roles: [ "customer" ],
      tax_registration_attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", valid_from: Date.new(2026, 4, 1)
      },
      actor: @org.user
    )
    @service = Items::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        code: "IMPLEMENT", name: "Implementation services", item_type: "service",
        hsn_sac_code: "998311", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
        cess_rate_basis_points: 0, income_account_code: "4000", expense_account_code: "5000"
      },
      actor: @org.user
    )
    @contract = Contracts::Create.call(
      tenant: @org.tenant, party_id: @customer.id, actor: @org.user,
      attributes: {
        title: "Milestone implementation", contract_type: "service_agreement",
        effective_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 6, 30),
        term_type: "fixed", currency: "INR", total_contract_value_minor: 30_000,
        jurisdiction: "IN", stamp_status: "pending", signature_status: "unsigned",
        registration_required: false, registration_status: "not_required",
        gst_treatment: "domestic_b2b", place_of_supply_state_code: "27"
      }
    )
    @obligation = Contracts::PerformanceObligations.create!(
      contract: @contract, actor: @org.user,
      attributes: {
        description: "Accepted implementation", satisfaction: "point_in_time",
        standalone_selling_price_minor: 30_000, ssp_method: "observable",
        service_end_date: Date.new(2026, 6, 30), revenue_account_code: "4000"
      }
    )
    @first_milestone = add_milestone("Configuration", Date.new(2026, 5, 31), 10_000)
    @second_milestone = add_milestone("Go-live", Date.new(2026, 6, 30), 20_000)
    activate_and_schedule
  end

  test "a linked invoice bills contract liability instead of recognizing revenue" do
    invoice = build_invoice

    assert_equal @contract.id, invoice.contract_id
    assert_equal @contract.contract_number, invoice.contract_snapshot.fetch("contractNumber")
    simulation = Documents::Simulate.call(invoice)
    assert simulation[:balanced]
    assert_equal [ "1200", "2200", "2100", "2100" ], simulation[:lines].pluck(:account_code)

    entry = Documents::Post.call(invoice, actor: "u:#{@org.user.id}")

    assert_equal [ "1200", "2200", "2100", "2100" ], entry.entry_lines.order(:line_no).pluck(:account_code)
    deferred = entry.entry_lines.find_by!(account_code: "2200")
    assert_equal(-10_000, deferred.amounts.find_by!(slot_role: "transaction").amount_minor)
    assert_equal @contract.id, deferred.extra.fetch("contractSnapshot").fetch("id")
  end

  test "posting runs release deferred revenue then create an unbilled contract asset exactly once" do
    invoice = build_invoice
    Documents::Post.call(invoice, actor: "u:#{@org.user.id}")
    Contracts::Milestones.achieve!(
      milestone: @first_milestone, actor: @org.user, achieved_date: Date.new(2026, 5, 31)
    )
    Contracts::Milestones.achieve!(
      milestone: @second_milestone, actor: @org.user, achieved_date: Date.new(2026, 6, 30)
    )

    simulation = Contracts::RunRevenueRecognition.call(
      contract: @contract, actor: @org.user, posting_date: Date.new(2026, 6, 30),
      mode: "simulate", idempotency_key: "rr-sim-#{@contract.id}"
    )
    assert_equal "simulated", simulation.status
    assert_equal 30_000, simulation.result.fetch("revenue_minor")
    assert_equal 10_000, simulation.result.fetch("contract_liability_minor")
    assert_equal 20_000, simulation.result.fetch("contract_asset_minor")
    assert_equal 0, ContractScheduleLine.where(status: "posted").count

    before_events = LedgerEvent.for_tenant(@org.tenant.id).count
    run = Contracts::RunRevenueRecognition.call(
      contract: @contract, actor: @org.user, posting_date: Date.new(2026, 6, 30),
      mode: "post", idempotency_key: "rr-post-#{@contract.id}"
    )

    assert_equal "posted", run.status
    assert_equal 2, run.result.fetch("posted")
    assert_equal before_events + 2, LedgerEvent.for_tenant(@org.tenant.id).count
    assert_equal 2, ContractScheduleLine.where(tenant_id: @org.tenant.id, status: "posted").count

    entries = run.contract_posting_run_items.order(:id).map { |item| Entry.find_by!(ledger_event_id: item.ledger_event_id) }
    assert_equal [ "2200", "4000" ], entries.first.entry_lines.order(:line_no).pluck(:account_code)
    assert_equal [ 10_000, -10_000 ], transaction_amounts(entries.first)
    assert_equal [ "1190", "4000" ], entries.second.entry_lines.order(:line_no).pluck(:account_code)
    assert_equal [ 20_000, -20_000 ], transaction_amounts(entries.second)

    same_run = Contracts::RunRevenueRecognition.call(
      contract: @contract, actor: @org.user, posting_date: Date.new(2026, 6, 30),
      mode: "post", idempotency_key: "rr-post-#{@contract.id}"
    )
    assert_equal run.id, same_run.id
    assert_equal before_events + 2, LedgerEvent.for_tenant(@org.tenant.id).count
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]
  end

  test "a credit note against contract billing reduces deferred revenue and the billed position" do
    invoice = build_invoice
    Documents::Post.call(invoice, actor: "u:#{@org.user.id}")
    note = CreditNotes::BuildDraft.call(
      tenant: @org.tenant, invoice_id: invoice.id,
      document_date: Date.new(2026, 5, 2), reason_code: "value_reduction",
      lines: [ { document_line_id: invoice.document_lines.first.id, quantity: "0.5" } ]
    )

    entry = Documents::Post.call(note, actor: "u:#{@org.user.id}")

    assert_equal @contract.id, note.contract_id
    assert_equal [ "1200", "2200", "2100", "2100" ], entry.entry_lines.order(:line_no).pluck(:account_code)
    assert_equal 5_000, entry.entry_lines.find_by!(account_code: "2200")
      .amounts.find_by!(slot_role: "transaction").amount_minor
    assert_equal 5_000, Contracts::RunRevenueRecognition.posted_billing(
      @contract, Date.new(2026, 5, 31)
    )
  end

  test "an unachieved milestone remains blocked and does not post" do
    run = Contracts::RunRevenueRecognition.call(
      contract: @contract, actor: @org.user, posting_date: Date.new(2026, 6, 30),
      mode: "post", idempotency_key: "rr-blocked-#{@contract.id}"
    )

    assert_equal "posted", run.status
    assert_equal 2, run.result.fetch("blocked")
    assert_equal [ "skipped" ], run.contract_posting_run_items.distinct.pluck(:status)
    assert_equal 0, ContractScheduleLine.where(tenant_id: @org.tenant.id, status: "posted").count
  end

  private

  def add_milestone(description, date, amount)
    Contracts::Milestones.create!(
      obligation: @obligation, actor: @org.user,
      attributes: {
        description: description, planned_date: date, recognition_amount_minor: amount,
        triggers_recognition: true
      }
    )
  end

  def activate_and_schedule
    Contracts::Transition.call(
      contract: @contract, to: "signed", actor: @org.user, occurred_on: Date.new(2026, 3, 31)
    )
    Contracts::Transition.call(
      contract: @contract, to: "active", actor: @org.user, occurred_on: Date.new(2026, 4, 1)
    )
    Contracts::AllocateTransactionPrice.call(
      contract: @contract, actor: @org.user, effective_date: Date.new(2026, 4, 1)
    )
    Contracts::GenerateRevenueSchedules.call(contract: @contract, actor: @org.user)
  end

  def build_invoice
    SalesInvoices::BuildDraft.call(
      tenant: @org.tenant, party_id: @customer.id,
      tax_registration_id: @seller_registration.id, contract_id: @contract.id,
      document_date: Date.new(2026, 5, 1), due_date: Date.new(2026, 5, 31),
      place_of_supply_state_code: "27", actor: @org.user,
      lines: [ { item_id: @service.id, quantity: "1", unit_price: "100.00" } ]
    )
  end

  def transaction_amounts(entry)
    entry.entry_lines.order(:line_no).map do |line|
      line.amounts.find_by!(slot_role: "transaction").amount_minor
    end
  end
end
