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

  private

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
