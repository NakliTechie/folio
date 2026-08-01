# frozen_string_literal: true

require "test_helper"

class ForeignExchangeTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "foreign-exchange@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Foreign Exchange"
    )
  end

  test "foreign journal freezes spot conversion in transaction and functional slots" do
    spot = create_rate("JPY", "INR", Date.new(2026, 8, 1), "0.55", "spot")
    document = build_foreign_journal

    translations = document.document_lines.order(:line_no).map do |line|
      line.extra.fetch("currencyTranslation")
    end
    assert_equal [ 55_000, -55_000 ], translations.pluck("functionalAmountMinor")
    assert_equal [ spot.id ], translations.pluck("exchangeRateId").uniq
    assert_equal [ "0.55" ], translations.pluck("rate").uniq

    simulation = Documents::Simulate.call(document)
    assert simulation[:balanced]
    assert_equal %w[functional transaction], simulation[:lines].first.fetch(:amounts).pluck(:slot_role).sort

    entry = Documents::Post.call(
      document, actor: "u:#{@org.user.id}", authorize: { user: @org.user }
    )
    bank = entry.entry_lines.find_by!(account_code: "1010")
    assert_equal 1_000, bank.amounts.find_by!(slot_role: "transaction").amount_minor
    functional = bank.amounts.find_by!(slot_role: "functional")
    assert_equal 55_000, functional.amount_minor
    assert_equal BigDecimal("0.55"), functional.rate
    assert_equal Date.new(2026, 8, 1), functional.rate_date
    assert EventSigning.verify(LedgerEvent.find(entry.ledger_event_id))
  end

  test "closing revaluation posts gains and later losses without rewriting historical translation" do
    create_rate("JPY", "INR", Date.new(2026, 8, 1), "0.55", "spot")
    document = build_foreign_journal
    Documents::Post.call(
      document, actor: "u:#{@org.user.id}", authorize: { user: @org.user }
    )
    create_rate("JPY", "INR", Date.new(2026, 8, 31), "0.60", "closing")

    events_before_simulation = LedgerEvent.for_tenant(@org.tenant.id).count
    simulation = ForeignExchange::Revalue.call(
      tenant: @org.tenant, actor: @org.user, revaluation_date: Date.new(2026, 8, 31),
      mode: "simulate", idempotency_key: "fx-sim-1"
    )
    item = simulation.exchange_revaluation_items.sole
    assert_equal [ 1_000, 55_000, 60_000, 5_000 ], [
      item.foreign_balance_minor, item.carrying_functional_minor,
      item.target_functional_minor, item.difference_minor
    ]
    assert_equal events_before_simulation, LedgerEvent.for_tenant(@org.tenant.id).count

    first = ForeignExchange::Revalue.call(
      tenant: @org.tenant, actor: @org.user, revaluation_date: Date.new(2026, 8, 31),
      mode: "post", idempotency_key: "fx-post-1"
    )
    first_entry = Entry.find_by!(ledger_event_id: first.ledger_event_id)
    assert_equal [ "1010", "4100" ], first_entry.entry_lines.order(:line_no).pluck(:account_code)
    assert_equal [ 5_000, -5_000 ], transaction_amounts(first_entry)

    create_rate("JPY", "INR", Date.new(2026, 9, 30), "0.58", "closing")
    second = ForeignExchange::Revalue.call(
      tenant: @org.tenant, actor: @org.user, revaluation_date: Date.new(2026, 9, 30),
      mode: "post", idempotency_key: "fx-post-2"
    )
    second_item = second.exchange_revaluation_items.sole
    assert_equal 60_000, second_item.carrying_functional_minor
    assert_equal(-2_000, second_item.difference_minor)
    second_entry = Entry.find_by!(ledger_event_id: second.ledger_event_id)
    assert_equal [ "1010", "5200" ], second_entry.entry_lines.order(:line_no).pluck(:account_code)
    assert_equal [ -2_000, 2_000 ], transaction_amounts(second_entry)

    original = Entry.find(document.reload.posted_entry_id).entry_lines.find_by!(account_code: "1010")
    assert_equal 55_000, original.amounts.find_by!(slot_role: "functional").amount_minor
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]
  end

  test "rates use the latest eligible effective date support reciprocal conversion and are immutable" do
    rate = create_rate("INR", "USD", Date.new(2026, 7, 31), "0.012", "spot")

    translation = ForeignExchange.translate(
      tenant_id: @org.tenant.id, amount_minor: 100,
      from_currency: "USD", to_currency: "INR", on: Date.new(2026, 8, 1), rate_type: "spot"
    )

    assert_equal 8_333, translation.amount_minor
    assert_equal "Approved treasury feed (reciprocal)", translation.rate_source
    assert_not rate.update(rate: "0.013")
    assert_includes rate.errors.full_messages.to_sentence, "immutable"
    assert_raises(ForeignExchange::MissingRate) do
      ForeignExchange.translate(
        tenant_id: @org.tenant.id, amount_minor: 100,
        from_currency: "EUR", to_currency: "INR", on: Date.new(2026, 8, 1), rate_type: "spot"
      )
    end
  end

  private

  def create_rate(from, to, date, rate, rate_type)
    ForeignExchange::Rates.create!(
      tenant: @org.tenant, actor: @org.user,
      attributes: {
        from_currency: from, to_currency: to, effective_on: date,
        rate: rate, rate_type: rate_type, source: "Approved treasury feed"
      }
    )
  end

  def build_foreign_journal
    Documents::BuildDraft.call(
      tenant: @org.tenant, doc_type: "JV",
      document_date: Date.new(2026, 8, 1), posting_date: Date.new(2026, 8, 1),
      narration: "JPY bank funding",
      lines: [
        { account_code: "1010", amount_minor: 1_000, currency: "JPY" },
        { account_code: "3000", amount_minor: -1_000, currency: "JPY" }
      ]
    )
  end

  def transaction_amounts(entry)
    entry.entry_lines.order(:line_no).map do |line|
      line.amounts.find_by!(slot_role: "transaction").amount_minor
    end
  end
end
