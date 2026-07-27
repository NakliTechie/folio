# frozen_string_literal: true

require "test_helper"
require "json"

class LedgerEventTest < ActiveSupport::TestCase
  # --- never-degrade property #3: append-only is a DB guarantee, not a convention ---

  test "the database rejects UPDATE on ledger_events" do
    e = append_one(1, "a")
    err = assert_raises(ActiveRecord::StatementInvalid) do
      LedgerEvent.connection.execute(
        "UPDATE ledger_events SET actor = 'tampered' WHERE id = #{e.id}"
      )
    end
    assert_match(/append-only/, err.message)
  end

  test "the database rejects DELETE on ledger_events" do
    e = append_one(2, "a")
    err = assert_raises(ActiveRecord::StatementInvalid) do
      LedgerEvent.connection.execute("DELETE FROM ledger_events WHERE id = #{e.id}")
    end
    assert_match(/append-only/, err.message)
  end

  test "the database rejects TRUNCATE on ledger_events" do
    append_one(3, "a")
    err = assert_raises(ActiveRecord::StatementInvalid) do
      LedgerEvent.connection.execute("TRUNCATE ledger_events")
    end
    assert_match(/append-only/, err.message)
  end

  # --- chain mechanics ---

  test "appending links each event to the previous head and starts at genesis" do
    a = append_one(10, "first")
    b = append_one(10, "second")

    assert_equal Folio::KhataHash::GENESIS_PREV, a.prev_hash
    assert_equal a.hash_hex, b.prev_hash
    assert_equal [ 1, 2 ], [ a.seq, b.seq ]
    assert LedgerEvent.verify_chain(10)[:ok]
  end

  test "verify_chain reports the exact seq where a chain breaks" do
    append_one(11, "first")
    b = append_one(11, "second")

    # Forge a divergent row directly, bypassing append! (the trigger blocks UPDATE,
    # so a tamperer's only move is to insert a competing row — which is precisely
    # what verify_chain must catch).
    LedgerEvent.connection.execute(<<~SQL)
      INSERT INTO ledger_events
        (tenant_id, seq, prev_hash, hash_hex, hash_version, ts, actor, action, origin, payload, recorded_at)
      VALUES
        (11, 3, '#{b.hash_hex}', '#{'f' * 64}', 2, '2026-07-27T00:00:03Z',
         'mallory', 'test.forged', 'test', '{}', clock_timestamp())
    SQL

    result = LedgerEvent.verify_chain(11)
    assert_not result[:ok]
    assert_equal 3, result[:broken_at]
  end

  test "payload must be canonicalised before hashing, not re-serialised after" do
    # Key order differs, canonical form must not.
    a = Folio::KhataHash.canonical_payload({ "b" => 2, "a" => 1 })
    b = Folio::KhataHash.canonical_payload({ "a" => 1, "b" => 2 })
    assert_equal a, b
    assert_equal '{"a":1,"b":2}', a
  end

  # --- H1: the walk must follow seq, not primary key ---

  test "verify_chain follows seq even when id order disagrees" do
    tenant = 20
    # Build a valid two-link chain by hand, then INSERT IT BACKWARDS so the row with
    # seq=2 gets the lower id. Every prior test inserted in sequence, which made id
    # order and seq order identical and hid the fact that find_each batched by id.
    rows = build_chain(tenant, %w[first second])
    LedgerEvent.insert_all!([ rows[1], rows[0] ])

    by_id  = LedgerEvent.for_tenant(tenant).order(:id).pluck(:seq)
    by_seq = LedgerEvent.for_tenant(tenant).order(:seq).pluck(:seq)
    assert_equal [ 2, 1 ], by_id,  "setup failed: ids must disagree with seq for this test to bite"
    assert_equal [ 1, 2 ], by_seq

    result = LedgerEvent.verify_chain(tenant)
    assert result[:ok], "walked in the wrong order — reason=#{result[:reason]} at seq=#{result[:broken_at]}"
    assert_equal 2, result[:rows]
    assert_equal rows[1][:hash_hex], result[:head]
  end

  # --- L3: a gap is indistinguishable from a deletion ---

  test "verify_chain reports a seq gap" do
    tenant = 21
    rows = build_chain(tenant, %w[a b c])
    LedgerEvent.insert_all!([ rows[0], rows[2] ]) # seq 1 and 3, no 2

    result = LedgerEvent.verify_chain(tenant)
    assert_not result[:ok]
    assert_equal :seq_gap, result[:reason]
    assert_equal 3, result[:broken_at]
  end

  private

  # Builds a correctly-hashed chain as plain attribute hashes, without going through
  # append! — so a test can control insertion order and seq independently.
  def build_chain(tenant_id, markers)
    prev = Folio::KhataHash::GENESIS_PREV
    now = Time.now.utc
    markers.each_with_index.map do |marker, i|
      payload = Folio::KhataHash.canonical_payload({ "marker" => marker })
      ts = "2026-07-28T00:00:0#{i}Z"
      hash_hex = Folio::KhataHash.event_hash(
        prev_hash: prev, ts: ts, actor: "tester", action: "test.event",
        ref: nil, origin: "test", payload_str: payload
      )
      row = {
        tenant_id: tenant_id, seq: i + 1, prev_hash: prev, hash_hex: hash_hex,
        hash_version: 2, ts: ts, actor: "tester", action: "test.event",
        ref: nil, origin: "test", payload: payload, recorded_at: now
      }
      prev = hash_hex
      row
    end
  end

  def append_one(tenant_id, marker)
    LedgerEvent.append!(
      tenant_id: tenant_id,
      actor: "tester",
      action: "test.event",
      origin: "test",
      ts: "2026-07-27T00:00:00Z",
      payload_str: Folio::KhataHash.canonical_payload({ "marker" => marker })
    )
  end
end
