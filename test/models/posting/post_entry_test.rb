# frozen_string_literal: true

require "test_helper"

# B3.2 — Posting::PostEntry: balance per (ledger, slot, currency), fat events with
# provenance + authority, and a PURE replay path. Runs in CI.
class Posting::PostEntryTest < ActiveSupport::TestCase
  PRIMARY = 1
  MGMT = 2 # a second (extension) ledger, for the per-ledger balance case

  def draft(**over)
    {
      tenant_id: 42, entity_id: 1, office_id: 1, actor: "u:1", origin: "folio",
      document_date: Date.new(2025, 6, 1), posting_date: Date.new(2025, 6, 1),
      entered_at: Time.utc(2025, 6, 2, 9, 0), fiscal_year: 2025, period_no: 3,
      authority: { role_template_id: 7, posting_limit_id: 3 },
      config_versions: { "document_types" => 7, "rule_sets" => 12 },
      lines: [
        { line_no: 1, account_code: "100100", ledger_id: PRIMARY, entity_id: 1, office_id: 1,
          amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2, amount_minor: 100_000 } ] },
        { line_no: 2, account_code: "400000", ledger_id: PRIMARY, entity_id: 1, office_id: 1,
          amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2, amount_minor: -100_000 } ] }
      ]
    }.merge(over)
  end

  # ---- pure balance semantics (no DB) ----
  test "a single-currency voucher balances per (ledger, slot, currency)" do
    assert Posting::PostEntry.balanced?(draft[:lines])
  end

  test "balance is per-ledger — a set that nets to zero GLOBALLY but not per ledger is rejected" do
    lines = [
      { ledger_id: PRIMARY, amounts: [ { slot_role: "transaction", currency: "INR", amount_minor: 100_000 } ] },
      { ledger_id: MGMT,    amounts: [ { slot_role: "transaction", currency: "INR", amount_minor: -100_000 } ] }
    ]
    # A global Dr=Cr check sums to zero and WRONGLY passes.
    assert_equal 0, lines.sum { |l| l[:amounts].sum { |a| a[:amount_minor] } }
    # The per-(ledger, slot, currency) check catches both unbalanced ledgers.
    offenders = Posting::PostEntry.balance_offenders(lines)
    assert_equal 2, offenders.size, "each ledger slice is individually unbalanced"
    assert offenders.key?([ PRIMARY, "transaction", "INR" ])
    assert offenders.key?([ MGMT, "transaction", "INR" ])
  end

  test "balance is per-currency within a slot — mixed currencies must each net to zero" do
    lines = [
      { ledger_id: PRIMARY, amounts: [ { slot_role: "transaction", currency: "USD", amount_minor: 100 } ] },
      { ledger_id: PRIMARY, amounts: [ { slot_role: "transaction", currency: "EUR", amount_minor: -100 } ] }
    ]
    refute Posting::PostEntry.balanced?(lines), "USD and EUR do not offset each other"
  end

  # ---- POST path ----
  test "post! writes a fat entry.posted event and projects it; the chain still verifies" do
    entry = Posting::PostEntry.post!(draft)
    assert entry.persisted?
    assert_equal 2, entry.entry_lines.count
    assert_equal 7, entry.role_template_id, "authority is projected onto the entry"

    event = LedgerEvent.find(entry.ledger_event_id)
    assert_equal "entry.posted", event.action
    result = LedgerEvent.verify_chain(42)
    assert result[:ok], "chain broke at seq=#{result[:broken_at]} (#{result[:reason]})"
  end

  test "post! raises UnbalancedError and writes nothing when a slice does not balance" do
    bad = draft
    bad[:lines][1][:amounts][0][:amount_minor] = -99_999 # off by one paise
    before = LedgerEvent.for_tenant(42).count
    assert_raises(Posting::UnbalancedError) { Posting::PostEntry.post!(bad) }
    assert_equal before, LedgerEvent.for_tenant(42).count, "a rejected post appends no event"
    assert_equal 0, Entry.where(tenant_id: 42).count, "and projects nothing"
  end

  # ---- the fat-events guarantee: replay is a PURE function of the payload ----
  test "replay! reconstructs the projection identically from the payload alone" do
    entry = Posting::PostEntry.post!(draft(
      lines: [
        { line_no: 1, account_code: "100100", ledger_id: PRIMARY, entity_id: 1, office_id: 1,
          party_id: 55, party_role: "customer", open_item: true, item_class: "normal",
          assignment: "INV-1", baseline_date: Date.new(2025, 6, 1), due_date: Date.new(2025, 7, 1),
          extra: { "campaign" => "diwali" },
          amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2, amount_minor: 100_000 },
                     { slot_role: "group", currency: "USD", minor_unit_exponent: 2, amount_minor: 1_200,
                       rate: "83.33", rate_basis: "posting_date" } ] },
        { line_no: 2, account_code: "400000", ledger_id: PRIMARY, entity_id: 1, office_id: 1,
          is_negative_posting: false,
          amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2, amount_minor: -100_000 },
                     { slot_role: "group", currency: "USD", minor_unit_exponent: 2, amount_minor: -1_200,
                       rate: "83.33", rate_basis: "posting_date" } ] }
      ]
    ))
    before = fingerprint(entry)
    event = LedgerEvent.find(entry.ledger_event_id)

    entry.destroy! # wipe the projection; the event (source of truth) remains
    assert_equal 0, Entry.where(tenant_id: 42).count

    replayed = Posting::PostEntry.replay!(event)
    assert_equal before, fingerprint(replayed),
      "replay from the event alone must reproduce the projection byte-for-byte — no derivation"
  end

  # ---- D15: the fat payload omits absent keys, never emits null ----
  test "the payload carries no null and omits absent optional keys" do
    json = Folio::KhataHash.canonical_payload(Posting::PostEntry.build_payload(draft))
    refute_includes json, "null", "a null-valued key would change the preimage and break the corpus"
    refute_includes json, "\"taxRegistrationId\"", "an absent optional dimension must be omitted, not null"
    assert_includes json, "\"authorizedUnder\"", "provenance authority is present"
    assert_includes json, "\"engineVersion\"", "provenance engine version is present"
  end

  test "a false open_item / is_negative_posting is omitted from the payload (defaults on replay)" do
    line = Posting::PostEntry.deep_compact(
      Posting::PostEntry.line_payload(
        line_no: 1, account_code: "x", ledger_id: 1, entity_id: 1, office_id: 1,
        open_item: false, is_negative_posting: false, amounts: []
      )
    )
    refute line.key?("openItem"), "a false open_item is omitted (D15), replay defaults it false"
    refute line.key?("isNegativePosting"), "a false is_negative_posting is omitted (D15)"
  end

  private

  # A stable representation of the projection that ignores surrogate ids / timestamps /
  # the event link, so "identical projection" means identical ACCOUNTING content.
  def fingerprint(entry)
    {
      entry: entry.slice("document_date", "posting_date", "entered_at", "fiscal_year",
                         "period_no", "role_template_id", "posting_limit_id"),
      lines: entry.entry_lines.order(:line_no).map do |l|
        {
          line: l.slice("line_no", "account_code", "ledger_id", "entity_id", "office_id",
                        "party_id", "party_role", "open_item", "item_class", "assignment",
                        "baseline_date", "due_date", "is_negative_posting", "line_class",
                        "posting_layer", "extra"),
          amounts: l.amounts.order(:slot_role, :currency).map do |a|
            a.slice("slot_role", "currency", "minor_unit_exponent", "amount_minor",
                    "rate", "rate_date", "rate_source", "rate_basis")
          end
        }
      end
    }
  end
end
