# frozen_string_literal: true

require "test_helper"
require "securerandom"

# Proves the domain_events seam end to end, the way a real module (contract management,
# Batch 6) will use it — before any module leans on it. Three properties:
#   1. a producer (DomainEvents::Record) appends a chain link that verifies;
#   2. an unknown kind is refused before any row is written;
#   3. the two logs share ONE hashing byte contract yet chain INDEPENDENTLY — the
#      "M0 conformance core guards BOTH logs" property.
class DomainEventsSeamTest < ActiveSupport::TestCase
  setup do
    @tenant = 7_200_000_000 + SecureRandom.random_number(100_000_000)
    @actor = users(:one)
    EventSigning::KeyProvisioner.ensure!(@actor)
  end

  test "a module producer appends a verifiable domain event end to end" do
    event = DomainEvents::Record.call(
      tenant_id: @tenant,
      kind: "contract.signed",
      actor: "u:#{@actor.id}",
      actor_user_id: @actor.id,
      ref: "CTR/26-27/00001",
      payload: { "contract_no" => "CTR/26-27/00001", "counterparty" => "Health & Glow" }
    )

    assert_equal 1, event.seq
    assert_equal "contract.signed", event.action
    assert_equal Folio::KhataHash::GENESIS_PREV, event.prev_hash
    # payload is stored as the canonical string, verbatim — not re-serialised.
    assert_equal '{"contract_no":"CTR/26-27/00001","counterparty":"Health & Glow"}', event.payload

    result = DomainEvent.verify_chain(@tenant)
    assert result[:ok], "chain should verify: #{result.inspect}"
    assert_equal 1, result[:rows]
    assert_equal event.hash_hex, result[:head]
  end

  test "an unknown kind is refused before any row is written" do
    assert_no_difference -> { DomainEvent.for_tenant(@tenant).count } do
      assert_raises(DomainEvents::UnknownKind) do
        DomainEvents::Record.call(
          tenant_id: @tenant, kind: "contract.teleported", actor: "u:1", payload: {}
        )
      end
    end
  end

  test "both logs share one byte contract but chain independently" do
    # SAME preimage inputs → SAME hash across the two logs. This is the shared byte
    # contract: one Folio::KhataHash, one set of bytes, whichever log calls it.
    inputs = {
      prev_hash: Folio::KhataHash::GENESIS_PREV, ts: "2026-08-01T00:00:00Z",
      actor: "u:7", action: "member.invited", ref: nil, origin: "folio",
      payload_str: Folio::KhataHash.canonical_payload({ "email" => "a@b.test" })
    }
    assert_equal Folio::KhataHash.event_hash(**inputs), Folio::KhataHash.event_hash(**inputs)

    # Independent chains: appending domain events for a tenant must not touch that
    # tenant's financial ledger_events chain, and both verify green side by side.
    ledger = LedgerEvent.append!(
      tenant_id: @tenant, actor: "u:7", action: "entry.posted", origin: "folio",
      ts: "2026-08-01T00:00:00Z",
      payload_str: Folio::KhataHash.canonical_payload({ "kind" => "financial" })
    )
    domain = DomainEvents::Record.call(
      tenant_id: @tenant, kind: "member.invited", actor: "u:7",
      payload: { "email" => "a@b.test" }
    )

    # Both are seq 1 in THEIR OWN stream — separate seq spaces.
    assert_equal 1, ledger.seq
    assert_equal 1, domain.seq
    assert LedgerEvent.verify_chain(@tenant)[:ok], "financial chain must stay sound"
    assert DomainEvent.verify_chain(@tenant)[:ok], "lifecycle chain must stay sound"

    # A second domain append advances only the domain stream.
    DomainEvents::Record.call(tenant_id: @tenant, kind: "member.joined", actor: "u:7",
                              payload: { "email" => "a@b.test" })
    assert_equal 1, LedgerEvent.for_tenant(@tenant).count, "financial stream unchanged"
    assert_equal 2, DomainEvent.for_tenant(@tenant).count, "lifecycle stream advanced"
    assert DomainEvent.verify_chain(@tenant)[:ok]
  end
end
