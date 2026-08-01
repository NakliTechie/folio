# frozen_string_literal: true

require "test_helper"

class ProcurementTest < ActiveSupport::TestCase
  DATE = Date.new(2026, 8, 1)

  setup do
    @org = Onboarding::SignUp.call(
      email: "procurement@folio.invalid", password: "correct-horse-battery",
      org_name: "Procurement Accounting"
    )
    @entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office.update!(
      address_line1: "1 Ledger Lane", city: "Mumbai", postal_code: "400001",
      state_code: "27", country_code: "IN"
    )
    @registration = TaxRegistrations::Manage.create!(
      tenant: @org.tenant, entity: @entity, actor: @org.user,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2026, 4, 1)
      },
      office_ids: [ @office.id ]
    )
    @vendor = Parties::Manage.create!(
      tenant: @org.tenant, actor: @org.user,
      attributes: {
        party_number: "V-PROC", name: "Procurement Vendor", state_code: "27", country_code: "IN",
        address_line1: "2 Supply Road", city: "Mumbai", postal_code: "400002"
      },
      roles: [ "vendor" ],
      tax_registration_attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", valid_from: Date.new(2026, 4, 1)
      }
    )
    @good = create_item(
      code: "STEEL", name: "Steel", item_type: "good", hsn: "7208",
      unit: "KGS", inventory_class: "raw_material", inventory_account: "1300"
    )
    @service = create_item(
      code: "LEGAL", name: "Legal services", item_type: "service", hsn: "998211", unit: "OTH"
    )
    @warehouse = Warehouse.find_by!(tenant_id: @org.tenant.id, code: "MAIN")
    @checker = invite_user("procurement-checker@folio.invalid", "accountant")
    @profile = Procurement::ManageVendor.onboard!(
      tenant: @org.tenant, actor: @org.user,
      attributes: { party_id: @vendor.id, payment_terms_days: 30, preferred_currency: "INR" }
    )
  end

  test "vendor and purchase-order approval enforce maker-checker authority" do
    error = assert_raises(Procurement::InvalidProcurement) do
      Procurement::ManageVendor.approve!(profile: @profile, actor: @org.user)
    end
    assert_match(/creator cannot approve/, error.message)
    Procurement::ManageVendor.approve!(profile: @profile, actor: @checker)
    assert_equal [ "approved", true, @checker.id ],
      @profile.reload.values_at(:status, :spend_authorized, :approved_by_id)

    order = create_order(lines: [ good_line(quantity: "10", price: "100") ])
    assert_equal "PO/2026-27/00001", order.order_number
    assert_nil order.approved_by_id
    assert_raises(Procurement::InvalidProcurement) do
      Procurement::ApproveOrder.call(order: order, actor: @org.user)
    end
    Procurement::ApproveOrder.call(order: order, actor: @checker)
    assert_equal [ "approved", @checker.id ], order.reload.values_at(:status, :approved_by_id)
    assert_equal %w[vendor.onboarded vendor.approved purchase_order.raised purchase_order.approved],
      DomainEvent.for_tenant(@org.tenant.id).order(:seq).pluck(:action).last(4)
    assert DomainEvent.verify_chain(@org.tenant.id)[:ok]
  end

  test "goods receipt is exact idempotent immutable and posts inventory against GRNI" do
    approve_profile!
    order = create_order(lines: [ good_line(quantity: "10", price: "100") ])
    Procurement::ApproveOrder.call(order: order, actor: @checker)

    before_events = LedgerEvent.for_tenant(@org.tenant.id).count
    error = assert_raises(Procurement::InvalidProcurement) do
      receive(order, quantity: "11", key: "over-receipt")
    end
    assert_match(/exceeds the open/, error.message)
    assert_equal before_events, LedgerEvent.for_tenant(@org.tenant.id).count
    assert_nil GoodsReceipt.find_by(tenant_id: @org.tenant.id, idempotency_key: "over-receipt")

    receipt = receive(order, quantity: "10", key: "receipt-1")
    assert_equal receipt.id, receive(order, quantity: "10", key: "receipt-1").id
    changed_input = Procurement::ReceiveOrder.normalize!(
      order,
      { received_on: DATE, external_reference: "DN-1", idempotency_key: "receipt-1" },
      [ { purchase_order_line_id: order.purchase_order_lines.sole.id, quantity: "9" } ]
    )
    refute_equal receipt.request_sha256, changed_input.fetch(:request_sha256)
    assert_match(/already belongs/, assert_raises(Procurement::InvalidProcurement) {
      receive(order, quantity: "9", key: "receipt-1")
    }.message)
    assert_equal "received", order.reload.status
    transaction = receipt.goods_receipt_lines.sole.inventory_transaction
    entry = Entry.find_by!(ledger_event_id: transaction.ledger_event_id)
    assert_equal [ "1300", "2050" ], entry.entry_lines.order(:line_no).pluck(:account_code)
    amounts = entry.entry_lines.order(:line_no).map do |line|
      line.amounts.find_by!(slot_role: "transaction").amount_minor
    end
    assert_equal [ 100_000, -100_000 ], amounts
    assert_equal [ 10.to_d, 100_000 ], StockBalance.find_by!(item: @good, warehouse: @warehouse)
      .values_at(:quantity, :inventory_value_minor)
    assert_raises(ActiveRecord::StatementInvalid) do
      GoodsReceipt.transaction(requires_new: true) { receipt.update_column(:external_reference, "rewrite") }
    end
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]
  end

  test "service acceptance stays non-financial" do
    approve_profile!
    order = create_order(lines: [ service_line(quantity: "2", price: "50") ])
    Procurement::ApproveOrder.call(order: order, actor: @checker)
    before = LedgerEvent.for_tenant(@org.tenant.id).count

    receipt = receive(order, quantity: "2", key: "service-acceptance")

    assert_nil receipt.goods_receipt_lines.sole.inventory_transaction_id
    assert_equal before, LedgerEvent.for_tenant(@org.tenant.id).count
    assert_equal "received", order.reload.status
  end

  test "PO bill matching clears GRNI and preserves advisory discrepancy evidence" do
    approve_profile!
    order = create_order(lines: [ good_line(quantity: "10", price: "100") ])
    Procurement::ApproveOrder.call(order: order, actor: @checker)
    receive(order, quantity: "10", key: "billable-receipt")

    bill = build_bill(order: order, quantity: "10", price: "100", reference: "MATCH-1")
    match = bill.procurement_matches.sole
    assert_equal "matched", match.status
    assert_equal "2050", bill.document_lines.sole.account_code
    entry = Documents::Post.call(bill, actor: "u:#{@org.user.id}")
    assert_equal [ "2000", "2050", "1210", "1210" ], entry.entry_lines.order(:line_no).pluck(:account_code)
    reversal = Documents::Reverse.call(bill, actor: "u:#{@org.user.id}")
    assert_equal [ "2000", "2050", "1210", "1210" ],
      reversal.entry_lines.order(:line_no).pluck(:account_code)
    assert_equal "reversed", bill.reload.state

    exception_order = create_order(lines: [ good_line(quantity: "5", price: "100") ])
    Procurement::ApproveOrder.call(order: exception_order, actor: @checker)
    exception_bill = build_bill(
      order: exception_order, quantity: "6", price: "110", reference: "MATCH-EXCEPTION"
    )
    evidence = exception_bill.procurement_matches.sole
    assert_equal "exception", evidence.status
    assert_equal %w[quantity_over_order price_variance receipt_shortfall],
      evidence.exceptions.pluck("code")
    assert Documents::Simulate.call(exception_bill).fetch(:balanced)
  end

  test "posting hold blocks new bills and suspension blocks new orders" do
    approve_profile!
    open_bill = build_bill(
      order: nil, quantity: "1", price: "100", reference: "BEFORE-HOLD", item: @service
    )
    open_entry = Documents::Post.call(open_bill, actor: "u:#{@org.user.id}")
    Procurement::ManageVendor.suspend!(profile: @profile, actor: @checker, reason: "Compliance review")
    assert_raises(Procurement::InvalidProcurement) do
      create_order(lines: [ service_line(quantity: "1", price: "100") ])
    end
    error = assert_raises(PurchaseBills::InvalidBill) do
      build_bill(order: nil, quantity: "1", price: "100", reference: "HELD-BILL", item: @service)
    end
    assert_match(/posting hold/, error.message)
    payable = open_entry.entry_lines.find_by!(account_code: "2000")
    payment_error = assert_raises(Settlements::InvalidSettlement) do
      Settlements::BuildDraft.call(
        tenant: @org.tenant, doc_type: "PY", document_date: DATE,
        bank_account_code: "1010",
        allocations: [ {
          target_entry_line_id: payable.id,
          amount: format("%.2f", Posting::Clearing.open_amount(payable) / 100.0),
          clearing_mode: "partial"
        } ]
      )
    end
    assert_match(/payment hold/, payment_error.message)
  end

  private

  def approve_profile!
    Procurement::ManageVendor.approve!(profile: @profile, actor: @checker)
  end

  def create_order(lines:)
    Procurement::CreateOrder.call(
      tenant: @org.tenant, actor: @org.user,
      attributes: {
        vendor_profile_id: @profile.id, order_date: DATE, expected_on: DATE + 7,
        description: "Governed purchase"
      },
      lines: lines
    )
  end

  def good_line(quantity:, price:)
    { item_id: @good.id, warehouse_id: @warehouse.id, quantity: quantity, unit_price: price }
  end

  def service_line(quantity:, price:)
    { item_id: @service.id, quantity: quantity, unit_price: price }
  end

  def receive(order, quantity:, key:)
    Procurement::ReceiveOrder.call(
      order: order, actor: @org.user,
      attributes: {
        received_on: DATE, external_reference: "DN-1", idempotency_key: key
      },
      lines: [ { purchase_order_line_id: order.purchase_order_lines.sole.id, quantity: quantity } ]
    )
  end

  def build_bill(order:, quantity:, price:, reference:, item: @good)
    PurchaseBills::BuildDraft.call(
      tenant: @org.tenant, actor: @org.user, party_id: @vendor.id,
      tax_registration_id: @registration.id, document_date: DATE, due_date: DATE + 30,
      external_reference: reference, purchase_order_id: order&.id,
      lines: [ { item_id: item.id, quantity: quantity, unit_price: price } ]
    )
  end

  def create_item(code:, name:, item_type:, hsn:, unit:, inventory_class: nil, inventory_account: nil)
    Items::Manage.create!(
      tenant: @org.tenant, actor: @org.user,
      attributes: {
        code: code, name: name, item_type: item_type, hsn_sac_code: hsn,
        unit_of_measure: unit, tax_rate_basis_points: 1800, cess_rate_basis_points: 0,
        income_account_code: "4000", expense_account_code: "5000",
        inventory_class: inventory_class, revision: item_type == "good" ? "A" : nil,
        valuation_method: item_type == "good" ? "moving_average" : nil,
        inventory_account_code: inventory_account
      }
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
