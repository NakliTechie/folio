# frozen_string_literal: true

require "test_helper"
require "securerandom"

class InventoryConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    token = SecureRandom.hex(8)
    @tenant = Tenant.create!(
      id: 6_500_000_000 + SecureRandom.random_number(100_000_000),
      name: "Inventory Race #{token}", slug: "inventory-race-#{token}"
    )
    spine = Onboarding::Seeds.org_spine!(@tenant)
    Onboarding::Seeds.warehouse!(
      @tenant, entity: spine.fetch(:entity), office: spine.fetch(:office)
    )
    Onboarding::Seeds.chart_of_accounts!(@tenant)
    Onboarding::Seeds.document_types!(@tenant)
    Rbac::Presets.seed_for!(@tenant)
    @user = users(:one)
    Membership.create!(tenant: @tenant, user: @user)
    UserOfficeRole.create!(
      tenant_id: @tenant.id, user: @user, office_id: nil,
      role_template: Rbac::Presets.role_for(@tenant, "owner")
    )
    @item = Items::Manage.create!(
      tenant: @tenant, actor: @user,
      attributes: {
        code: "RACE", name: "Race stock", item_type: "good", hsn_sac_code: "7208",
        unit_of_measure: "NOS", tax_rate_basis_points: 1800, cess_rate_basis_points: 0,
        income_account_code: "4000", expense_account_code: "5000",
        inventory_class: "trading", revision: "A", valuation_method: "moving_average",
        inventory_account_code: "1300"
      }
    )
    @warehouse = Warehouse.find_by!(tenant_id: @tenant.id, code: "MAIN")
    post("receipt", "10", key: "opening", destination: @warehouse, unit_cost: "100", offset: "3000")
  end

  teardown do
    # This test deliberately commits work from multiple connections. Each parallel test
    # worker has its own database. Temporarily disable only the new statement-level
    # TRUNCATE guards (row UPDATE/DELETE immutability stays active), clean test-owned rows,
    # and restore the guards even if cleanup fails.
    connection = ActiveRecord::Base.connection
    guarded = connection.select_rows(<<~SQL)
      SELECT quote_ident(class.relname), quote_ident(trigger.tgname)
      FROM pg_trigger trigger
      JOIN pg_class class ON class.oid = trigger.tgrelid
      JOIN pg_proc function ON function.oid = trigger.tgfoid
      WHERE function.proname = 'folio_immutable_evidence_no_truncate'
    SQL
    guarded.each do |table, trigger|
      connection.execute("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}")
    end
    connection.execute(<<~SQL)
      TRUNCATE TABLE inventory_movements, inventory_transactions, stock_balances, warehouses
      RESTART IDENTITY CASCADE
    SQL
  ensure
    guarded&.each do |table, trigger|
      connection&.execute("ALTER TABLE #{table} ENABLE TRIGGER #{trigger}")
    end
  end

  test "competing issues serialize and cannot overdraw the valuation layer" do
    ready = Queue.new
    start = Queue.new
    outcomes = Array.new(2)
    threads = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          outcomes[index] = post(
            "issue", "7", key: "issue-#{index}", source: @warehouse, offset: "5000"
          )
        rescue StandardError => e
          outcomes[index] = e
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each(&:join)

    assert_equal 1, outcomes.count { |outcome| outcome.is_a?(InventoryTransaction) }
    assert_equal [ Inventory::InvalidMovement ], outcomes.grep(Exception).map(&:class)
    balance = StockBalance.find_by!(tenant_id: @tenant.id, item: @item, warehouse: @warehouse)
    assert_equal [ 3.to_d, 30_000 ], balance.values_at(:quantity, :inventory_value_minor)
    assert_equal 2, InventoryTransaction.where(tenant_id: @tenant.id).count
    assert LedgerEvent.verify_chain(@tenant.id)[:ok]
  end

  private

  def post(type, quantity, key:, source: nil, destination: nil, unit_cost: nil, offset: nil)
    Inventory::PostMovement.call(
      tenant: @tenant, actor: @user,
      attributes: {
        transaction_type: type, posting_date: "2026-08-01", item_id: @item.id,
        quantity: quantity, unit_cost: unit_cost, source_warehouse_id: source&.id,
        destination_warehouse_id: destination&.id, offset_account_code: offset,
        reason: "Concurrency probe", idempotency_key: key
      }
    )
  end
end
