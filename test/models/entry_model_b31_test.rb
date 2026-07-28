# frozen_string_literal: true

require "test_helper"

# B3.1 — regression cover for the FULL-SPEC fields the M-lock spec tests do not assert
# (owner decision: build every field in entry-model-v1.md, add tests for the gap). These
# run in CI. The schema-shape assertions live in test/spec/entry_model_spec_test.rb.
class EntryModelB31Test < ActiveSupport::TestCase
  setup do
    @entry = Entry.create!(
      tenant_id: 42, document_date: Date.new(2025, 6, 1), posting_date: Date.new(2025, 6, 1),
      entered_at: Time.utc(2025, 6, 2, 9, 0), fiscal_year: 2025, period_no: 3
    )
  end

  def build_line(**over)
    EntryLine.new({
      tenant_id: 42, entry_id: @entry.id, line_no: 1, account_code: "400000",
      ledger_id: 1, entity_id: 1, office_id: 1
    }.merge(over))
  end

  # --- D6: period identity is stored and domain-checked ---
  test "period_no accepts special periods and carryforward, rejects out of range" do
    assert Entry.new(tenant_id: 1, document_date: Date.today, posting_date: Date.today,
                     entered_at: Time.now, fiscal_year: 2025, period_no: 0).valid?, "period 0 = carryforward"
    assert Entry.new(tenant_id: 1, document_date: Date.today, posting_date: Date.today,
                     entered_at: Time.now, fiscal_year: 2025, period_no: 14).valid?, "13-16 = special periods"
    bad = Entry.new(tenant_id: 1, document_date: Date.today, posting_date: Date.today,
                    entered_at: Time.now, fiscal_year: 2025, period_no: 17)
    assert_not bad.valid?, "17 is out of the {0}∪[1..16] domain"
  end

  test "the period_no CHECK constraint rejects an out-of-range value at the DB, not just the model" do
    assert_raises(ActiveRecord::StatementInvalid) do
      # Bypass the model validation to prove the DB constraint is real.
      Entry.connection.execute(
        "INSERT INTO entries (tenant_id, document_date, posting_date, entered_at, fiscal_year, period_no, created_at, updated_at) " \
        "VALUES (1, '2025-06-01', '2025-06-01', now(), 2025, 99, now(), now())"
      )
    end
  end

  # --- D2: committed dimension defaults + the uncommitted bag ---
  test "line_class defaults to real and posting_layer to 00" do
    line = build_line
    assert line.valid?, line.errors.full_messages.join(", ")
    line.save!
    assert_equal "real", line.reload.line_class
    assert_equal "00", line.posting_layer
  end

  test "extra jsonb round-trips an uncommitted dimension" do
    line = build_line(extra: { "campaign" => "diwali-2025", "channel" => "whatsapp" })
    line.save!
    assert_equal "diwali-2025", line.reload.extra["campaign"]
  end

  # --- D5: item_class domain (replaces SAP Special G/L) ---
  test "item_class is constrained to the four classes" do
    assert build_line(open_item: true, item_class: "down_payment").valid?
    assert build_line(open_item: true, item_class: "noted").valid?
    assert_not build_line(open_item: true, item_class: "special_gl").valid?,
      "there is no Special G/L class — item_class is the whole replacement"
  end

  # --- D6/D5 gap fields the spec tests do not assert but the spec requires ---
  test "value_date and movement_type are real columns on the line" do
    line = build_line(value_date: Date.new(2025, 6, 3), movement_type: "101")
    line.save!
    assert_equal Date.new(2025, 6, 3), line.reload.value_date
    assert_equal "101", line.movement_type
  end

  test "line_no is unique within (entry, ledger)" do
    build_line(line_no: 1, ledger_id: 1).save!
    dup = build_line(line_no: 1, ledger_id: 1)
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
    # ...but the same line_no on a DIFFERENT ledger is fine (multi-ledger posting).
    assert build_line(line_no: 1, ledger_id: 2).save
  end

  # --- D7: reversal is distinguishable from a counter-posting ---
  test "is_negative_posting is a real boolean, defaulting false" do
    line = build_line
    line.save!
    assert_equal false, line.reload.is_negative_posting
    assert build_line(line_no: 2, is_negative_posting: true).save
  end

  # --- D4: signed minor units, ISO 4217 exponent, NO debit/credit pair ---
  test "amounts are signed minor units with a per-currency exponent" do
    line = build_line
    line.save!
    jpy = JournalEntryLineAmount.create!(tenant_id: 42, entry_line_id: line.id,
      slot_role: "transaction", currency: "JPY", minor_unit_exponent: 0, amount_minor: 82_000)
    assert_equal 0, jpy.reload.minor_unit_exponent, "JPY has no minor unit — exponent 0, not a ×100 assumption"
    credit = JournalEntryLineAmount.create!(tenant_id: 42, entry_line_id: line.id,
      slot_role: "functional", currency: "INR", minor_unit_exponent: 2, amount_minor: -8_200_000)
    assert credit.amount_minor.negative?, "a credit is a negative signed amount, not a separate column"
  end

  test "journal_entry_line_amounts carries no debit or credit column" do
    %w[debit credit dr cr].each do |c|
      assert_not JournalEntryLineAmount.column_names.include?(c),
        "`#{c}` must not exist — debit/credit lives only in the .khata export projection"
    end
  end

  test "slot_role and rate_basis are constrained; the group slot must pin its basis" do
    line = build_line
    line.save!
    assert_not JournalEntryLineAmount.new(tenant_id: 42, entry_line_id: line.id,
      slot_role: "reporting", currency: "INR", minor_unit_exponent: 2, amount_minor: 1).valid?
    # a group slot carrying a rate must state what date the rate is on (§4 non-negotiable #2)
    grp = JournalEntryLineAmount.new(tenant_id: 42, entry_line_id: line.id, slot_role: "group",
      currency: "USD", minor_unit_exponent: 2, amount_minor: 1, rate: 83.1)
    assert_not grp.valid?, "a translated group amount must pin its rate_basis"
    grp.rate_basis = "posting_date"
    assert grp.valid?
  end
end

# The statutory number series is NOT a Postgres sequence — it must be gapless under
# concurrency, which sequences are not. This proves the SELECT ... FOR UPDATE row lock in
# NumberRange.allocate! serialises concurrent allocators with no gaps and no duplicates.
# Non-transactional: the threads use separate connections and must see committed rows.
class NumberRangeConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  TENANT = 999_001

  setup do
    NumberRange.where(tenant_id: TENANT).delete_all
    @range = NumberRange.create!(tenant_id: TENANT, entity_id: 1, office_id: 1,
      doc_type: "JV", fiscal_year: 2025, next_value: 1)
  end

  teardown do
    NumberRange.where(tenant_id: TENANT).delete_all
  end

  test "concurrent allocation is gapless and collision-free" do
    threads = 4
    per_thread = 10
    results = Array.new(threads) { [] }

    threads.times.map { |i|
      Thread.new do
        per_thread.times do
          results[i] << NumberRange.allocate!(tenant_id: TENANT, entity_id: 1, office_id: 1,
            doc_type: "JV", fiscal_year: 2025)
        end
      ensure
        ActiveRecord::Base.connection_pool.release_connection
      end
    }.each(&:join)

    all = results.flatten.sort
    assert_equal (1..threads * per_thread).to_a, all,
      "expected a gapless 1..#{threads * per_thread} with no duplicates; got #{all.inspect}"
    assert_equal threads * per_thread + 1, @range.reload.next_value
  end
end
