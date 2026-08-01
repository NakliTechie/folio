# frozen_string_literal: true

require "test_helper"

class InventoryTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "inventory@folio.invalid", password: "correct-horse-battery",
      org_name: "Inventory Accounting"
    )
    @item = create_item("STEEL")
    @main = Warehouse.find_by!(tenant_id: @org.tenant.id, code: "MAIN")
    @secondary = Inventory::ManageWarehouse.create!(
      tenant: @org.tenant, actor: @org.user,
      attributes: { code: "WIP", name: "Work in progress", warehouse_type: "wip" }
    )
  end

  test "moving average receipts, issues, and transfers tie stock to signed ledger lines" do
    first = post_movement(
      type: "receipt", quantity: "10", unit_cost: "100", destination: @main,
      offset: "3000", key: "receipt-1"
    )
    post_movement(
      type: "receipt", quantity: "10", unit_cost: "200", destination: @main,
      offset: "3000", key: "receipt-2"
    )
    balance = StockBalance.find_by!(item: @item, warehouse: @main)
    assert_equal 20.to_d, balance.quantity
    assert_equal 300_000, balance.inventory_value_minor
    assert_equal 15_000, balance.average_unit_cost_minor

    issue = post_movement(
      type: "issue", quantity: "4", source: @main, offset: "5000", key: "issue-1"
    )
    assert_equal 60_000, issue.total_value_minor
    assert_equal [ 60_000, -60_000 ], transaction_amounts(issue)
    stock_line = Entry.find_by!(ledger_event_id: issue.ledger_event_id)
      .entry_lines.find_by!(account_code: "1300")
    assert_equal [ @item.id, @main.id, -4.to_d, "moving_average" ],
      [ stock_line.item_id, stock_line.warehouse_id, stock_line.quantity, stock_line.valuation_view ]

    transfer = post_movement(
      type: "transfer", quantity: "6", source: @main, destination: @secondary,
      key: "transfer-1"
    )
    assert_equal 90_000, transfer.total_value_minor
    assert_equal [ 90_000, -90_000 ], transaction_amounts(transfer)
    assert_equal [ 10.to_d, 150_000 ], balance.reload.values_at(:quantity, :inventory_value_minor)
    secondary = StockBalance.find_by!(item: @item, warehouse: @secondary)
    assert_equal [ 6.to_d, 90_000 ], secondary.values_at(:quantity, :inventory_value_minor)

    event = LedgerEvent.find(first.ledger_event_id)
    assert EventSigning.verify(event)
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]
    Posting.rebuild!(@org.tenant.id)
    rebuilt = Entry.find_by!(ledger_event_id: issue.ledger_event_id).entry_lines.find_by!(account_code: "1300")
    assert_equal @main.id, rebuilt.warehouse_id
    assert_equal "moving_average", rebuilt.valuation_view

    Inventory::RebuildBalances.call(tenant_id: @org.tenant.id)
    assert_equal [ 10.to_d, 150_000 ], StockBalance.find_by!(item: @item, warehouse: @main)
      .values_at(:quantity, :inventory_value_minor)
    assert_equal [ 6.to_d, 90_000 ], StockBalance.find_by!(item: @item, warehouse: @secondary)
      .values_at(:quantity, :inventory_value_minor)
  end

  test "idempotency is exact and insufficient stock writes nothing" do
    original = post_movement(
      type: "receipt", quantity: "2", unit_cost: "50", destination: @main,
      offset: "3000", key: "same-key"
    )
    duplicate = post_movement(
      type: "receipt", quantity: "2", unit_cost: "50", destination: @main,
      offset: "3000", key: "same-key"
    )
    assert_equal original.id, duplicate.id
    assert_equal 1, InventoryTransaction.where(tenant_id: @org.tenant.id).count

    assert_match(/already belongs/, assert_raises(Inventory::InvalidMovement) {
      post_movement(
        type: "receipt", quantity: "3", unit_cost: "50", destination: @main,
        offset: "3000", key: "same-key"
      )
    }.message)
    before_events = LedgerEvent.for_tenant(@org.tenant.id).count
    assert_match(/insufficient stock/, assert_raises(Inventory::InvalidMovement) {
      post_movement(type: "issue", quantity: "3", source: @main, offset: "5000", key: "too-much")
    }.message)
    assert_equal before_events, LedgerEvent.for_tenant(@org.tenant.id).count
    assert_nil InventoryTransaction.find_by(tenant_id: @org.tenant.id, idempotency_key: "too-much")
  end

  test "inventory evidence is database immutable" do
    transaction = post_movement(
      type: "receipt", quantity: "2", unit_cost: "50", destination: @main,
      offset: "3000", key: "immutable"
    )
    assert_raises(ActiveRecord::StatementInvalid) do
      InventoryTransaction.transaction(requires_new: true) do
        transaction.update_column(:reason, "rewrite")
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      InventoryMovement.transaction(requires_new: true) do
        transaction.inventory_movements.sole.delete
      end
    end
    assert_equal "Stock receipt", transaction.reload.reason
    @item.assign_attributes(inventory_account_code: "1000")
    refute @item.valid?
    assert_includes @item.errors.full_messages.to_sentence, "locked after movement"
  end

  private

  def create_item(code)
    Items::Manage.create!(
      tenant: @org.tenant, actor: @org.user,
      attributes: {
        code: code, name: "Steel", item_type: "good", hsn_sac_code: "7208",
        unit_of_measure: "KGS", tax_rate_basis_points: 1800, cess_rate_basis_points: 0,
        income_account_code: "4000", expense_account_code: "5000",
        inventory_class: "raw_material", revision: "A", valuation_method: "moving_average",
        inventory_account_code: "1300"
      }
    )
  end

  def post_movement(type:, quantity:, key:, source: nil, destination: nil, unit_cost: nil, offset: nil)
    Inventory::PostMovement.call(
      tenant: @org.tenant, actor: @org.user,
      attributes: {
        transaction_type: type, posting_date: "2026-08-01", item_id: @item.id,
        quantity: quantity, unit_cost: unit_cost, source_warehouse_id: source&.id,
        destination_warehouse_id: destination&.id, offset_account_code: offset,
        reason: "Stock #{type.humanize.downcase}", idempotency_key: key
      }
    )
  end

  def transaction_amounts(transaction)
    Entry.find_by!(ledger_event_id: transaction.ledger_event_id).entry_lines.order(:line_no).map do |line|
      line.amounts.find_by!(slot_role: "transaction").amount_minor
    end
  end
end
