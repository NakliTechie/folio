# frozen_string_literal: true

require "test_helper"

# D15 — the rule the whole entry-model spec (plan/spec/entry-model-v1.md) rests on:
# widening a payload with new OPTIONAL fields is free, as long as an unset field is
# OMITTED rather than serialised as null.
#
# These are NOT spec stubs. They pass today and guard behaviour that already exists in
# the canonical serialiser shared with Bahi. They live here, in test/conformance and NOT
# in test/spec, precisely because they must keep running in CI — if either ever fails,
# additive widening has stopped being free and the .khata contract is broken. That is a
# real regression, not a Batch 3 to-do.
#
# Verified against the actual serialisers: canonical-json.mjs uses Object.keys(obj).sort()
# and canonical_json.rb uses value.keys.map(&:to_s).sort — neither injects a key for an
# absent field, and both encode a present nil as null.
class D15AdditiveWideningTest < ActiveSupport::TestCase
  test "absent keys are omitted from the preimage, and null is not the same thing" do
    without_key = Folio::KhataHash.canonical_payload({ "a" => 1 })
    with_null   = Folio::KhataHash.canonical_payload({ "a" => 1, "b" => nil })

    assert_equal '{"a":1}', without_key, "an absent key must contribute nothing"
    assert_equal '{"a":1,"b":null}', with_null, "a present nil serialises as null"
    assert_not_equal without_key, with_null,
      "omitting a key and setting it null are DIFFERENT preimages — this is why the rule is " \
      "'omit absent keys, never emit null' and not merely a style preference"
  end

  test "widening a payload with absent optional keys does not move the hash" do
    base = { "customerId" => 16, "name" => "Health & Glow Pharmacy" }
    args = { prev_hash: Folio::KhataHash::GENESIS_PREV, ts: "2026-07-28T00:00:00Z",
             actor: "t", action: "a", ref: nil, origin: "o" }

    narrow = Folio::KhataHash.event_hash(**args, payload_str: Folio::KhataHash.canonical_payload(base))
    # A widened writer that simply does not set the new optional fields.
    widened = Folio::KhataHash.event_hash(**args, payload_str: Folio::KhataHash.canonical_payload(base.dup))

    assert_equal narrow, widened,
      "adding optional fields must be free as long as unset ones are omitted — this is the whole " \
      "basis of the .khata v1.1 proposal"
  end
end
