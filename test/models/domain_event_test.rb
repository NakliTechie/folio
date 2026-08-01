# frozen_string_literal: true

require "test_helper"
require "json"
require "securerandom"

# Structural twin of LedgerEventTest. The chain mechanics are mirrored on purpose, so
# the same adversarial cases (append-only, seq gap, id-vs-seq order, bigint tenant,
# nil genesis) are exercised against the second log. The one behaviour unique to
# domain_events — governed kinds — has its own cases at the bottom.
class DomainEventTest < ActiveSupport::TestCase
  setup do
    @tenant_base = 7_100_000_000 + SecureRandom.random_number(100_000_000)
  end

  # --- append-only is a DB guarantee, not a convention (mirrors ledger_events) ---

  test "the database rejects UPDATE on domain_events" do
    e = append_one(test_tenant_id(1))
    err = assert_raises(ActiveRecord::StatementInvalid) do
      DomainEvent.connection.execute(
        "UPDATE domain_events SET actor = 'tampered' WHERE id = #{e.id}"
      )
    end
    assert_match(/append-only/, err.message)
  end

  test "the database rejects DELETE on domain_events" do
    e = append_one(test_tenant_id(2))
    err = assert_raises(ActiveRecord::StatementInvalid) do
      DomainEvent.connection.execute("DELETE FROM domain_events WHERE id = #{e.id}")
    end
    assert_match(/append-only/, err.message)
  end

  test "the database rejects TRUNCATE on domain_events" do
    append_one(test_tenant_id(3))
    err = assert_raises(ActiveRecord::StatementInvalid) do
      DomainEvent.connection.execute("TRUNCATE domain_events")
    end
    assert_match(/append-only/, err.message)
  end

  # --- chain mechanics ---

  test "appending links each event to the previous head and starts at genesis" do
    tenant = test_tenant_id(10)
    a = append_one(tenant)
    b = append_one(tenant)

    assert_equal Folio::KhataHash::GENESIS_PREV, a.prev_hash
    assert_equal a.hash_hex, b.prev_hash
    assert_equal [ 1, 2 ], [ a.seq, b.seq ]
    assert DomainEvent.verify_chain(tenant)[:ok]
  end

  test "verify_chain reports the exact seq where a chain breaks" do
    tenant = test_tenant_id(11)
    append_one(tenant)
    b = append_one(tenant)

    # Forge a divergent row directly, bypassing append! (the trigger blocks UPDATE, so a
    # tamperer's only move is to INSERT a competing row — which verify_chain must catch).
    DomainEvent.connection.execute(<<~SQL)
      INSERT INTO domain_events
        (tenant_id, seq, prev_hash, hash_hex, hash_version, ts, actor, action, origin, payload, recorded_at)
      VALUES
        (#{tenant}, 3, '#{b.hash_hex}', '#{'f' * 64}', 2, '2026-08-01T00:00:03Z',
         'mallory', 'contract.signed', 'test', '{}', clock_timestamp())
    SQL

    result = DomainEvent.verify_chain(tenant)
    assert_not result[:ok]
    assert_equal 3, result[:broken_at]
    assert_equal :hash_mismatch, result[:reason]
  end

  test "verify_chain follows seq even when id order disagrees" do
    tenant = test_tenant_id(20)
    rows = build_chain(tenant, %w[contract.drafted contract.signed])
    DomainEvent.insert_all!([ rows[1], rows[0] ]) # seq=2 gets the lower id

    by_id  = DomainEvent.for_tenant(tenant).order(:id).pluck(:seq)
    by_seq = DomainEvent.for_tenant(tenant).order(:seq).pluck(:seq)
    assert_equal [ 2, 1 ], by_id, "setup failed: ids must disagree with seq for this test to bite"
    assert_equal [ 1, 2 ], by_seq

    result = DomainEvent.verify_chain(tenant)
    assert result[:ok], "walked in the wrong order — reason=#{result[:reason]} at seq=#{result[:broken_at]}"
    assert_equal 2, result[:rows]
    assert_equal rows[1][:hash_hex], result[:head]
  end

  test "verify_chain reports a seq gap" do
    tenant = test_tenant_id(21)
    rows = build_chain(tenant, %w[contract.drafted contract.signed contract.activated])
    DomainEvent.insert_all!([ rows[0], rows[2] ]) # seq 1 and 3, no 2

    result = DomainEvent.verify_chain(tenant)
    assert_not result[:ok]
    assert_equal :seq_gap, result[:reason]
    assert_equal 3, result[:broken_at]
  end

  test "append! works for a tenant id above the int4 ceiling" do
    big = 3_100_000_000 # > 2**31-1; tenant_id is a bigint column
    a = append_one(big)
    b = append_one(big)

    assert_equal [ 1, 2 ], [ a.seq, b.seq ]
    assert_equal a.hash_hex, b.prev_hash
    assert DomainEvent.verify_chain(big)[:ok]
  end

  test "a seq below 1 is rejected by the database" do
    tenant = test_tenant_id(40)
    err = assert_raises(ActiveRecord::StatementInvalid) do
      DomainEvent.connection.execute(<<~SQL)
        INSERT INTO domain_events
          (tenant_id, seq, prev_hash, hash_hex, hash_version, ts, actor, action, origin, payload, recorded_at)
        VALUES (#{tenant}, 0, '#{'0' * 64}', '#{'f' * 64}', 2, 't', 'mallory', 'contract.signed', 'x', '{}', clock_timestamp())
      SQL
    end
    assert_match(/domain_events_seq_positive/, err.message)
  end

  test "prev_hash rejects nil at the model but still allows the genesis empty string" do
    e = DomainEvent.new(tenant_id: test_tenant_id(30), seq: 1, hash_hex: "0" * 64, ts: "t",
                        actor: "a", action: "contract.signed", origin: "o", payload: "{}")
    e.prev_hash = nil
    assert_not e.valid?
    assert_includes e.errors[:prev_hash].join, "not nil"

    e.prev_hash = ""
    e.valid?
    assert_empty e.errors[:prev_hash], "'' is a legal genesis prev_hash"
  end

  # --- governed kinds: the behaviour unique to domain_events ---

  test "append! rejects an unregistered kind at the model" do
    e = DomainEvent.new(tenant_id: test_tenant_id(50), seq: 1, prev_hash: "", hash_hex: "0" * 64,
                        ts: "t", actor: "a", action: "contract.teleported", origin: "o", payload: "{}")
    assert_not e.valid?
    assert_includes e.errors[:action].join, "not a registered"
  end

  test "every registered kind is accepted as an action" do
    DomainEvents::Kinds::ALL.each do |kind|
      e = DomainEvent.new(tenant_id: test_tenant_id(60), seq: 1, prev_hash: "", hash_hex: "0" * 64,
                          ts: "t", actor: "a", action: kind, origin: "o", payload: "{}")
      e.valid?
      assert_empty e.errors[:action], "#{kind} should be a valid action"
    end
  end

  private

  def test_tenant_id(offset)
    @tenant_base + offset
  end

  # Builds a correctly-hashed chain as plain attribute hashes, without append! — so a
  # test can control insertion order and seq independently. `markers` double as actions,
  # so they must be registered kinds.
  def build_chain(tenant_id, markers)
    prev = Folio::KhataHash::GENESIS_PREV
    now = Time.now.utc
    markers.each_with_index.map do |marker, i|
      payload = Folio::KhataHash.canonical_payload({ "marker" => marker })
      ts = "2026-08-01T00:00:0#{i}Z"
      hash_hex = Folio::KhataHash.event_hash(
        prev_hash: prev, ts: ts, actor: "tester", action: marker,
        ref: nil, origin: "test", payload_str: payload
      )
      row = {
        tenant_id: tenant_id, seq: i + 1, prev_hash: prev, hash_hex: hash_hex,
        hash_version: 2, ts: ts, actor: "tester", action: marker,
        ref: nil, origin: "test", payload: payload, recorded_at: now
      }
      prev = hash_hex
      row
    end
  end

  def append_one(tenant_id)
    DomainEvent.append!(
      tenant_id: tenant_id,
      actor: "tester",
      action: "contract.signed",
      origin: "test",
      ts: "2026-08-01T00:00:00Z",
      payload_str: Folio::KhataHash.canonical_payload({ "marker" => "x" })
    )
  end
end
