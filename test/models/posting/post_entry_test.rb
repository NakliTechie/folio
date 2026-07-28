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
  # Two independent teeth, because post! projects VIA replay! — so comparing a post
  # projection to a replay projection only proves determinism, not payload-faithfulness.

  # (1) Independent oracle: assert the projected values equal the KNOWN draft directly.
  # A derivation that hardcodes or computes a field wrongly (but deterministically) fails
  # HERE, where a round-trip comparison would not.
  test "post! projects each field faithfully from the draft (independent oracle)" do
    entry = Posting::PostEntry.post!(rich_draft)
    # entry header
    assert_equal Date.new(2025, 6, 1), entry.document_date
    assert_equal Date.new(2025, 6, 1), entry.posting_date
    assert_equal 2025, entry.fiscal_year
    assert_equal 3, entry.period_no
    assert_equal 7, entry.role_template_id
    assert_equal 3, entry.posting_limit_id
    # line 1 — the dimension-rich line
    l1 = entry.entry_lines.find_by!(line_no: 1)
    assert_equal "100100", l1.account_code
    assert_equal PRIMARY, l1.ledger_id
    assert_equal "real", l1.line_class,   "line_class must come from the payload, not a derivation"
    assert_equal "00", l1.posting_layer
    assert_equal 55, l1.party_id
    assert_equal "customer", l1.party_role
    assert l1.open_item
    assert_equal "normal", l1.item_class
    assert_equal({ "campaign" => "diwali" }, l1.extra)
    assert_equal Date.new(2025, 7, 1), l1.due_date
    txn = l1.amounts.find_by!(slot_role: "transaction")
    assert_equal "INR", txn.currency
    assert_equal 100_000, txn.amount_minor
    assert_equal 2, txn.minor_unit_exponent
    grp = l1.amounts.find_by!(slot_role: "group")
    assert_equal BigDecimal("83.33"), grp.rate
    assert_equal "posting_date", grp.rate_basis
    # line 2 — the balancing line (un-asserted fields slip past a round-trip; assert them)
    l2 = entry.entry_lines.find_by!(line_no: 2)
    assert_equal "400000", l2.account_code
    assert_equal(-100_000, l2.amounts.find_by!(slot_role: "transaction").amount_minor)
    assert_equal(-1_200, l2.amounts.find_by!(slot_role: "group").amount_minor)
    refute l2.open_item, "line 2 sets no open_item; it must default false, not inherit line 1"
  end

  # (2) Payload-independence: after posting, DELETE every master the projection references,
  # then replay from the event alone. A pure replay needs none of them; any lookup of a
  # ledger/dimension/party/etc. would now return nil and change (or break) the projection.
  test "replay! reconstructs from the event payload alone, with all master data deleted" do
    # Seed the EXACT masters the payload references (ids matched), so the deletion below
    # actually removes rows a stray lookup could have used — without this the delete_all is
    # a silent no-op and the guard is inert. A pure replay needs none of these.
    Entity.create!(id: 1, tenant_id: 42, code: "E1", legal_name: "Acme", functional_currency: "INR",
                   fiscal_year_variant: "IN_APR_MAR", jurisdiction_profile: "IN")
    Office.create!(id: 1, tenant_id: 42, entity_id: 1, code: "O1", name: "HQ")
    Ledger.create!(id: PRIMARY, tenant_id: 42, code: "PRIMARY", name: "Primary")
    Party.create!(id: 55, tenant_id: 42, party_number: "C-55", name: "Cust")

    entry = Posting::PostEntry.post!(rich_draft)
    before = fingerprint(entry)
    event = LedgerEvent.find(entry.ledger_event_id)

    entry.destroy!
    deleted = [ Ledger, Dimension, Party, PartyRole, TaxRegistration, Office, Entity ]
              .sum { |m| m.delete_all }
    assert_operator deleted, :>=, 4, "the deletion must actually remove the seeded masters"
    assert_equal 0, Entry.where(tenant_id: 42).count

    replayed = Posting::PostEntry.replay!(event)
    assert_equal before, fingerprint(replayed),
      "replay consulted master data — it must derive the projection from the event payload only"
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

  # A draft exercising the full committed dimension set, open-item state and two currency
  # slots, so the oracle and payload-independence tests have real content to check.
  def rich_draft
    draft(
      lines: [
        { line_no: 1, account_code: "100100", ledger_id: PRIMARY, entity_id: 1, office_id: 1,
          party_id: 55, party_role: "customer", open_item: true, item_class: "normal",
          assignment: "INV-1", baseline_date: Date.new(2025, 6, 1), due_date: Date.new(2025, 7, 1),
          extra: { "campaign" => "diwali" },
          amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2, amount_minor: 100_000 },
                     { slot_role: "group", currency: "USD", minor_unit_exponent: 2, amount_minor: 1_200,
                       rate: "83.33", rate_basis: "posting_date" } ] },
        { line_no: 2, account_code: "400000", ledger_id: PRIMARY, entity_id: 1, office_id: 1,
          amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2, amount_minor: -100_000 },
                     { slot_role: "group", currency: "USD", minor_unit_exponent: 2, amount_minor: -1_200,
                       rate: "83.33", rate_basis: "posting_date" } ] }
      ]
    )
  end

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
