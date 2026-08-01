# frozen_string_literal: true

require "test_helper"

class FixedAssetsTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "assets@folio.invalid", password: "correct-horse-battery",
      org_name: "Asset Accounting"
    )
    @asset = FixedAssets::Manage.create!(
      tenant: @org.tenant, actor: @org.user,
      attributes: {
        asset_class_id: AssetClass.find_by!(tenant_id: @org.tenant.id, code: "PPE").id,
        asset_number: "1000", component_number: "0001", name: "CNC spindle",
        capitalization_date: "2026-04-01", quantity: "1", unit_of_measure: "EA",
        serial_number: "SP-100"
      },
      book_terms: {
        useful_life_months: 12, residual_value_minor: 12_000,
        depreciation_start_date: "2026-04-01"
      },
      tax_terms: {
        useful_life_months: 12, residual_value_minor: 12_000,
        depreciation_start_date: "2026-04-01"
      }
    )
  end

  test "acquisition capitalizes book and statistical tax valuations with typed ledger evidence" do
    transaction = acquire
    assert_equal "active", @asset.reload.status
    assert_equal 2, @asset.asset_transactions.count
    assert_equal [ 120_000, 120_000 ], @asset.asset_valuations.order(:valuation_code).pluck(:gross_block_minor)

    book = @asset.asset_valuations.find_by!(valuation_code: "BOOK")
    tax = @asset.asset_valuations.find_by!(valuation_code: "TAX_IT")
    assert book.posts_to_ledger?
    refute tax.posts_to_ledger?
    assert transaction.ledger_event_id
    assert_nil @asset.asset_transactions.find_by!(valuation_code: "TAX_IT").ledger_event_id

    asset_line = Entry.find_by!(ledger_event_id: transaction.ledger_event_id)
      .entry_lines.find_by!(account_code: "1400")
    assert_equal [ @asset.id, Date.new(2026, 4, 1), "BOOK" ],
      asset_line.values_at(:fixed_asset_id, :asset_value_date, :valuation_view)
    Posting.rebuild!(@org.tenant.id)
    rebuilt = Entry.find_by!(ledger_event_id: transaction.ledger_event_id)
      .entry_lines.find_by!(account_code: "1400")
    assert_equal [ @asset.id, Date.new(2026, 4, 1), "BOOK" ],
      rebuilt.values_at(:fixed_asset_id, :asset_value_date, :valuation_view)
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]
    assert DomainEvent.verify_chain(@org.tenant.id)[:ok]
  end

  test "depreciation simulates then posts a delta once across book and tax views" do
    acquire
    simulation = run_depreciation("simulate", key: "preview")
    assert_equal "simulated", simulation.status
    assert_equal 2, simulation.result.fetch("valuationCount")
    assert_equal 108_000, simulation.result.fetch("ledgerAmountMinor")
    assert_equal 2, @asset.asset_transactions.count

    posted = run_depreciation("post", key: "year-end")
    assert_equal "posted", posted.status
    assert_equal [ 108_000, 108_000 ], @asset.asset_valuations.order(:valuation_code)
      .pluck(:accumulated_depreciation_minor)
    assert_equal [ 12_000, 12_000 ], @asset.asset_valuations.order(:valuation_code)
      .map(&:net_book_value_minor)
    assert_equal 4, @asset.asset_transactions.count
    assert_equal 1, posted.asset_transactions.where.not(ledger_event_id: nil).count

    repeated = run_depreciation("post", key: "year-end-again")
    assert_equal 0, repeated.result.fetch("valuationCount")
    assert_equal 4, @asset.asset_transactions.count
    assert_equal posted.id, run_depreciation("post", key: "year-end").id
  end

  test "asset transactions are immutable and carrying amounts rebuild from them" do
    acquire
    run_depreciation("post", key: "rebuild-run")
    transaction = @asset.asset_transactions.find_by!(valuation_code: "BOOK", transaction_type: "acquisition")
    assert_raises(ActiveRecord::StatementInvalid) do
      AssetTransaction.transaction(requires_new: true) { transaction.update_column(:amount_minor, 1) }
    end

    @asset.asset_valuations.update_all(gross_block_minor: 1, accumulated_depreciation_minor: 0)
    FixedAssets::RebuildValuations.call(tenant_id: @org.tenant.id)
    assert_equal [ [ 120_000, 108_000 ], [ 120_000, 108_000 ] ],
      @asset.asset_valuations.order(:valuation_code)
        .pluck(:gross_block_minor, :accumulated_depreciation_minor)
  end

  test "depreciation cannot book a cumulative target into another accounting date" do
    acquire

    error = assert_raises(FixedAssets::InvalidAsset) do
      FixedAssets::RunDepreciation.call(
        tenant: @org.tenant, actor: @org.user,
        attributes: {
          through_date: "2027-03-31", posting_date: "2026-08-31",
          mode: "post", idempotency_key: "inverted-dates"
        }
      )
    end

    assert_match(/must equal/, error.message)
    assert_nil DepreciationRun.find_by(tenant_id: @org.tenant.id, idempotency_key: "inverted-dates")
  end

  test "component identity and tenant-scoped account determination are enforced" do
    duplicate = @asset.dup
    duplicate.created_domain_event = @asset.created_domain_event
    refute duplicate.valid?
    assert_includes duplicate.errors[:asset_number], "has already been taken"

    other = Onboarding::SignUp.call(
      email: "other-assets@folio.invalid", password: "correct-horse-battery", org_name: "Other Assets"
    )
    klass = @asset.asset_class.dup
    klass.code = "CROSS"
    klass.tenant_id = other.tenant.id
    klass.apc_account_code = "1499"
    refute klass.valid?
    assert_includes klass.errors.full_messages.to_sentence, "must be an active"
  end

  private

  def acquire
    FixedAssets::Acquire.call(
      asset: @asset, actor: @org.user,
      attributes: {
        amount: "1200", offset_account_code: "3000", asset_value_date: "2026-04-01",
        posting_date: "2026-04-01", external_reference: "CAPEX-1", idempotency_key: "acquire-1"
      }
    )
  end

  def run_depreciation(mode, key:)
    FixedAssets::RunDepreciation.call(
      tenant: @org.tenant, actor: @org.user,
      attributes: {
        through_date: "2027-03-31", posting_date: "2027-03-31",
        mode: mode, idempotency_key: key
      }
    )
  end
end
