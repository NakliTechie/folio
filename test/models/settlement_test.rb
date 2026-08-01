# frozen_string_literal: true

require "test_helper"

class SettlementTest < ActiveSupport::TestCase
  SETTLEMENT_DATE = Date.new(2026, 8, 15)

  setup do
    @org = Onboarding::SignUp.call(
      email: "settlement-model@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Settlement Model"
    )
    entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    office.update!(
      address_line1: "1 Ledger Lane", city: "Mumbai", postal_code: "400001",
      state_code: "27", country_code: "IN"
    )
    @registration = TaxRegistrations::Manage.create!(
      tenant: @org.tenant, entity: entity,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2026, 4, 1)
      },
      office_ids: [ office.id ], actor: @org.user
    )
    @customer = create_party("C-001", "Customer", "customer")
    @vendor = create_party(
      "V-001", "Vendor", "vendor", gstin: "29AAAAA0300L1Z8", state: "29"
    )
    @service = Items::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        code: "CONSULT", name: "Consulting services", item_type: "service",
        hsn_sac_code: "998311", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
        cess_rate_basis_points: 0, income_account_code: "4000", expense_account_code: "5000"
      },
      actor: @org.user
    )
    @invoice = SalesInvoices::BuildDraft.call(
      tenant: @org.tenant, party_id: @customer.id, tax_registration_id: @registration.id,
      document_date: Date.new(2026, 7, 31), due_date: Date.new(2026, 8, 30),
      place_of_supply_state_code: "27",
      lines: [ { item_id: @service.id, quantity: "2", unit_price: "50.00" } ]
    )
    Documents::Post.call(@invoice, actor: "u:#{@org.user.id}")
    @bill = PurchaseBills::BuildDraft.call(
      tenant: @org.tenant, party_id: @vendor.id, tax_registration_id: @registration.id,
      document_date: Date.new(2026, 7, 31), due_date: Date.new(2026, 8, 30),
      place_of_supply_state_code: "27", external_reference: "V-INV-001",
      place_of_supply_override_reason: "Supplier invoice records Maharashtra as the place of supply",
      actor: @org.user,
      lines: [ { item_id: @service.id, quantity: "2", unit_price: "50.00" } ]
    )
    Documents::Post.call(@bill, actor: "u:#{@org.user.id}")
    @receivable = stable_item(@invoice, "1200")
    @payable = stable_item(@bill, "2000")
  end

  test "a partial customer receipt preserves invoice ageing and clears its allocation side" do
    receipt = build_settlement("RC", @receivable, amount: "40.00", mode: "partial")
    entry = Documents::Post.call(receipt, actor: "u:#{@org.user.id}")

    assert_equal "RC/26-27/00001", receipt.reload.document_number
    assert_equal [ "1010", "1200" ], entry.entry_lines.order(:line_no).pluck(:account_code)
    amounts = entry.entry_lines.order(:line_no).map do |line|
      line.amounts.find_by!(slot_role: "transaction").amount_minor
    end
    assert_equal [ 4_000, -4_000 ], amounts

    receivable = stable_item(@invoice, "1200")
    assert_equal 4_000, receivable.cleared_amount_minor
    assert_nil receivable.cleared_on
    assert_equal Date.new(2026, 7, 31), receivable.baseline_date
    assert_equal 7_800, Posting::Clearing.open_amount(receivable)

    settlement_line = entry.entry_lines.find_by!(account_code: "1200")
    assert_equal SETTLEMENT_DATE, settlement_line.reload.cleared_on
    assert_equal 4_000, settlement_line.cleared_amount_minor
    allocation = receipt.document_allocations.first
    assert allocation.target_clearing_event_id
    assert allocation.settlement_clearing_event_id
  end

  test "a full vendor payment clears the payable and credits bank" do
    payment = build_settlement("PY", @payable, amount: "118.00", mode: "partial")
    entry = Documents::Post.call(payment, actor: "u:#{@org.user.id}")

    assert_equal "PY/26-27/00001", payment.reload.document_number
    amounts = entry.entry_lines.order(:line_no).map do |line|
      line.amounts.find_by!(slot_role: "transaction").amount_minor
    end
    assert_equal [ -11_800, 11_800 ], amounts
    payable = stable_item(@bill, "2000")
    assert_equal SETTLEMENT_DATE, payable.cleared_on
    assert_equal 0, Posting::Clearing.open_amount(payable)
  end

  test "residual clearing closes the original and re-baselines the balance" do
    receipt = build_settlement("RC", @receivable, amount: "40.00", mode: "residual")
    Documents::Post.call(receipt, actor: "u:#{@org.user.id}")

    original = stable_item(@invoice, "1200")
    assert_equal SETTLEMENT_DATE, original.cleared_on
    residual = original.residuals.first
    assert residual.open_item?
    assert_equal "statistical", residual.line_class
    assert_equal SETTLEMENT_DATE, residual.baseline_date
    assert_equal original.assignment, residual.assignment
    assert_equal 7_800, Posting::Clearing.open_amount(residual)

    trial_balance = Reports.trial_balance(@org.tenant.id)
    assert_equal trial_balance.sum { |row| row.fetch("debit") },
      trial_balance.sum { |row| row.fetch("credit") }

    day_book = Reports.day_book(
      @org.tenant.id, from_date: Date.new(2026, 7, 31), to_date: SETTLEMENT_DATE
    )
    assert_equal day_book.fetch(:debit_minor), day_book.fetch(:credit_minor)

    readiness = PeriodControls::Readiness.call(
      tenant: @org.tenant, fiscal_year: 2026, period_no: 5
    )
    assert readiness.fetch(:balanced)
  end

  test "settlements reject cross-party and wrong-role allocations" do
    other_customer = create_party(
      "C-002", "Other Customer", "customer",
      gstin: "29AAAAA0300L1Z8", state: "29", valid_from: Date.new(2026, 4, 2)
    )
    other_invoice = @invoice.dup
    other_invoice.assign_attributes(
      party_id: other_customer.id,
      state: "draft",
      document_number: nil,
      posted_entry_id: nil,
      party_snapshot: @invoice.party_snapshot.merge("id" => other_customer.id, "name" => other_customer.name)
    )
    other_invoice.save!
    @invoice.document_lines.each do |line|
      copy = line.dup
      copy.document = other_invoice
      copy.save!
    end
    Documents::Post.call(other_invoice, actor: "u:#{@org.user.id}")
    other_receivable = stable_item(other_invoice, "1200")

    error = assert_raises(Settlements::InvalidSettlement) do
      Settlements::BuildDraft.call(
        tenant: @org.tenant, doc_type: "RC", document_date: SETTLEMENT_DATE,
        bank_account_code: "1010",
        allocations: [ allocation(@receivable, "10.00"), allocation(other_receivable, "10.00") ]
      )
    end
    assert_match(/one counterparty/, error.message)

    error = assert_raises(Settlements::InvalidSettlement) do
      build_settlement("RC", @payable, amount: "10.00", mode: "partial")
    end
    assert_match(/eligible open customer item/, error.message)
  end

  test "posting serializes stale drafts and rejects an over-allocation before numbering" do
    first = build_settlement("RC", @receivable, amount: "100.00", mode: "partial")
    stale = build_settlement("RC", @receivable, amount: "100.00", mode: "partial")
    Documents::Post.call(first, actor: "u:#{@org.user.id}")

    error = assert_raises(Documents::InvalidDocument) do
      Documents::Post.call(stale, actor: "u:#{@org.user.id}")
    end
    assert_match(/exceeds the current outstanding/, error.message)
    assert_equal "draft", stale.reload.state
    assert_equal 2, NumberRange.find_by!(tenant_id: @org.tenant.id, doc_type: "RC").next_value
  end

  test "stable allocation targets survive a projection rebuild before posting" do
    receipt = build_settlement("RC", @receivable, amount: "40.00", mode: "partial")
    old_target_id = receipt.document_allocations.first.target_entry_line_id

    Posting.rebuild!(@org.tenant.id)
    new_target = receipt.document_allocations.first.target_item
    refute_nil new_target
    refute_equal old_target_id, new_target.id

    Documents::Post.call(receipt, actor: "u:#{@org.user.id}")
    assert_equal 7_800, Posting::Clearing.open_amount(receipt.document_allocations.first.target_item)
  end

  test "a generic draft cannot bypass the specialized settlement contract" do
    error = assert_raises(Documents::InvalidDocument) do
      Documents::BuildDraft.call(
        tenant: @org.tenant, doc_type: "RC",
        document_date: SETTLEMENT_DATE, posting_date: SETTLEMENT_DATE,
        narration: nil,
        lines: [
          { account_code: "1010", amount_minor: 100 },
          { account_code: "1200", amount_minor: -100 }
        ]
      )
    end
    assert_match(/specialized endpoint/, error.message)
  end

  test "reset appends compensating events and reopens both invoice and unapplied cash" do
    receipt = build_settlement("RC", @receivable, amount: "40.00", mode: "partial")
    Documents::Post.call(receipt, actor: "u:#{@org.user.id}")
    allocation = receipt.document_allocations.first

    Settlements::ResetAllocation.call(
      document: receipt, allocation_id: allocation.id,
      actor: "u:#{@org.user.id}", user: @org.user, reset_on: Date.new(2026, 8, 20)
    )

    assert allocation.reload.reset?
    assert_equal 11_800, Posting::Clearing.open_amount(allocation.target_item)
    settlement_line = EntryLine.joins(:entry).find_by!(
      entries: { document_id: receipt.id }, line_no: allocation.line_no + 1
    )
    assert_nil settlement_line.cleared_on
    assert_equal 4_000, Posting::Clearing.open_amount(settlement_line)
    assert_equal 2, LedgerEvent.where(
      tenant_id: @org.tenant.id, action: "items.clearing_reset"
    ).count

    Posting.rebuild!(@org.tenant.id)
    assert_equal 11_800, Posting::Clearing.open_amount(allocation.target_item)
    rebuilt_settlement = EntryLine.joins(:entry).find_by!(
      entries: { document_id: receipt.id }, line_no: allocation.line_no + 1
    )
    assert_equal 4_000, Posting::Clearing.open_amount(rebuilt_settlement)
  end

  test "a closed originating period blocks allocation reset without appending events" do
    receipt = build_settlement("RC", @receivable, amount: "40.00", mode: "partial")
    Documents::Post.call(receipt, actor: "u:#{@org.user.id}")
    allocation = receipt.document_allocations.first
    close_period_for!(@receivable)

    assert_no_difference -> { LedgerEvent.where(action: "items.clearing_reset").count } do
      error = assert_raises(Settlements::InvalidReset) do
        Settlements::ResetAllocation.call(
          document: receipt, allocation_id: allocation.id,
          actor: "u:#{@org.user.id}", user: @org.user, reset_on: Date.new(2026, 8, 20)
        )
      end
      assert_match(/period .* is closed/, error.message)
    end
    assert allocation.reload.applied?
  end

  test "a restricted originating period requires period-lock authority for reset" do
    receipt = build_settlement("RC", @receivable, amount: "40.00", mode: "partial")
    Documents::Post.call(receipt, actor: "u:#{@org.user.id}")
    allocation = receipt.document_allocations.first
    control_period_for!(@receivable, state: "restricted", capability: "period.lock")
    operator = invite_user("settlement-period-operator@folio.invalid", "operator")

    error = assert_raises(Settlements::InvalidReset) do
      Settlements::ResetAllocation.call(
        document: receipt, allocation_id: allocation.id,
        actor: "u:#{operator.id}", user: operator, reset_on: Date.new(2026, 8, 20)
      )
    end
    assert_match(/capability 'period.lock'/, error.message)

    Settlements::ResetAllocation.call(
      document: receipt, allocation_id: allocation.id,
      actor: "u:#{@org.user.id}", user: @org.user, reset_on: Date.new(2026, 8, 20)
    )
    assert allocation.reload.reset?
  end

  test "a closed new-target period blocks reallocation and preserves unapplied cash" do
    receipt = build_settlement("RC", @receivable, amount: "40.00", mode: "partial")
    Documents::Post.call(receipt, actor: "u:#{@org.user.id}")
    allocation = receipt.document_allocations.first
    Settlements::ResetAllocation.call(
      document: receipt, allocation_id: allocation.id,
      actor: "u:#{@org.user.id}", user: @org.user, reset_on: Date.new(2026, 8, 20)
    )
    later_invoice = SalesInvoices::BuildDraft.call(
      tenant: @org.tenant, party_id: @customer.id, tax_registration_id: @registration.id,
      document_date: Date.new(2026, 9, 1), due_date: Date.new(2026, 9, 30),
      place_of_supply_state_code: "27",
      lines: [ { item_id: @service.id, quantity: "1", unit_price: "50.00" } ]
    )
    Documents::Post.call(later_invoice, actor: "u:#{@org.user.id}")
    target = stable_item(later_invoice, "1200")
    close_period_for!(target)

    assert_no_difference "SettlementReallocation.count" do
      error = assert_raises(Settlements::InvalidReset) do
        Settlements::Reallocate.call(
          document: receipt, allocation_id: allocation.id, target_entry_line_id: target.id,
          clearing_mode: "partial", actor: "u:#{@org.user.id}", user: @org.user,
          applied_on: Date.new(2026, 9, 5)
        )
      end
      assert_match(/period .* is closed/, error.message)
    end
    assert allocation.reload.reset?
  end

  test "a reset receipt can be governedly reapplied to another invoice for the same customer" do
    second_invoice = SalesInvoices::BuildDraft.call(
      tenant: @org.tenant, party_id: @customer.id, tax_registration_id: @registration.id,
      document_date: Date.new(2026, 8, 1), due_date: Date.new(2026, 8, 31),
      place_of_supply_state_code: "27",
      lines: [ { item_id: @service.id, quantity: "1", unit_price: "50.00" } ]
    )
    Documents::Post.call(second_invoice, actor: "u:#{@org.user.id}")
    second_receivable = stable_item(second_invoice, "1200")
    receipt = build_settlement("RC", @receivable, amount: "40.00", mode: "partial")
    Documents::Post.call(receipt, actor: "u:#{@org.user.id}")
    allocation = receipt.document_allocations.first
    Settlements::ResetAllocation.call(
      document: receipt, allocation_id: allocation.id,
      actor: "u:#{@org.user.id}", user: @org.user, reset_on: Date.new(2026, 8, 20)
    )

    reallocation = Settlements::Reallocate.call(
      document: receipt, allocation_id: allocation.id,
      target_entry_line_id: second_receivable.id, clearing_mode: "partial",
      actor: "u:#{@org.user.id}", user: @org.user, applied_on: Date.new(2026, 8, 21)
    )

    assert reallocation.persisted?
    assert_equal 11_800, Posting::Clearing.open_amount(allocation.target_item)
    assert_equal 1_900, Posting::Clearing.open_amount(reallocation.target_item)
    settlement_line = EntryLine.joins(:entry).find_by!(
      entries: { document_id: receipt.id }, line_no: allocation.line_no + 1
    )
    assert_equal 0, Posting::Clearing.open_amount(settlement_line)
    assert_equal Date.new(2026, 8, 21), settlement_line.cleared_on
  end

  test "resetting residual clearing removes the residual and restores the original" do
    receipt = build_settlement("RC", @receivable, amount: "40.00", mode: "residual")
    Documents::Post.call(receipt, actor: "u:#{@org.user.id}")
    allocation = receipt.document_allocations.first
    assert allocation.target_item.residuals.exists?

    Settlements::ResetAllocation.call(
      document: receipt, allocation_id: allocation.id,
      actor: "u:#{@org.user.id}", user: @org.user, reset_on: Date.new(2026, 8, 20)
    )

    assert_not allocation.target_item.residuals.exists?
    assert_nil allocation.target_item.cleared_on
    assert_equal 11_800, Posting::Clearing.open_amount(allocation.target_item)
  end

  private

  def create_party(number, name, role, gstin: "27AAPFU0939F1ZV", state: "27",
                   valid_from: Date.new(2026, 4, 1))
    Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        party_number: number, name: name, state_code: state, country_code: "IN",
        address_line1: "2 Party Road", city: state == "27" ? "Mumbai" : "Bengaluru",
        postal_code: state == "27" ? "400002" : "560002"
      },
      roles: [ role ],
      tax_registration_attributes: {
        kind: "GSTIN", identifier: gstin, valid_from: valid_from
      },
      actor: @org.user
    )
  end

  def stable_item(document, account_code)
    EntryLine.joins(:entry).find_by!(entries: { document_id: document.id }, account_code: account_code)
  end

  def build_settlement(doc_type, target, amount:, mode:)
    Settlements::BuildDraft.call(
      tenant: @org.tenant,
      doc_type: doc_type,
      document_date: SETTLEMENT_DATE,
      bank_account_code: "1010",
      narration: "Bank settlement",
      allocations: [ allocation(target, amount, mode) ]
    )
  end

  def allocation(target, amount, mode = "partial")
    { target_entry_line_id: target.id, amount: amount, clearing_mode: mode }
  end

  def close_period_for!(line)
    control_period_for!(line, state: "closed")
  end

  def control_period_for!(line, state:, capability: nil)
    PeriodControl.create!(
      tenant_id: line.tenant_id, entity_id: line.entity_id, ledger_id: line.ledger_id,
      account_class: Posting::PostEntry.account_class_for(party_role: line.party_role),
      fiscal_year: line.entry.fiscal_year, period_no: line.entry.period_no,
      state: state, capability: capability, domain: "posting"
    )
  end

  def invite_user(email, role_code)
    invitation = Onboarding::Invite.create!(
      tenant: @org.tenant, email: email, role_code: role_code, invited_by: @org.user
    )
    Onboarding::Invite.accept!(
      token: invitation.generate_token_for(:invite), password: "correct-horse-battery"
    )
  end
end
