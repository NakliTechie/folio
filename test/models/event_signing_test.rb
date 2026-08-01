# frozen_string_literal: true

require "test_helper"

class EventSigningTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "event-signer@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Event Signer"
    )
  end

  test "signup provisions one encrypted P-256 key without storing private plaintext" do
    key = @org.user.user_signing_keys.active.sole

    assert_equal 1, key.key_version
    assert_equal "ecdsa-p256-sha256", key.algorithm
    assert_equal 64, key.fingerprint.length
    assert_match(/BEGIN PUBLIC KEY/, key.public_key_pem)
    refute_match(/BEGIN.*PRIVATE KEY/, key.encrypted_private_key)
    assert_match(/BEGIN.*PRIVATE KEY/, EventSigning::Cipher.decrypt(key.encrypted_private_key))
  end

  test "domain and financial events carry independently verifiable actor signatures" do
    customer = Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: { party_number: "C-SIGN", name: "Signed Customer", country_code: "IN", state_code: "27" },
      roles: [ "customer" ], actor: @org.user
    )
    contract = Contracts::Create.call(
      tenant: @org.tenant, party_id: customer.id, actor: @org.user,
      attributes: {
        title: "Signed contract event", contract_type: "service_agreement",
        effective_date: Date.new(2026, 8, 1), end_date: Date.new(2026, 8, 31),
        term_type: "fixed", currency: "INR", total_contract_value_minor: 10_000,
        jurisdiction: "IN", stamp_status: "pending", signature_status: "unsigned",
        registration_required: false, registration_status: "not_required",
        gst_treatment: "domestic_b2b", place_of_supply_state_code: "27"
      }
    )
    domain_event = contract.created_domain_event

    assert_equal @org.user.id, domain_event.actor_user_id
    assert_equal @org.user.user_signing_keys.active.sole.id, domain_event.signing_key_id
    assert EventSigning.verify(domain_event)

    voucher = Documents::BuildDraft.call(
      tenant: @org.tenant, doc_type: "JV",
      document_date: Date.new(2026, 8, 1), posting_date: Date.new(2026, 8, 1),
      narration: "Signed journal",
      lines: [
        { account_code: "1000", amount_minor: 10_000 },
        { account_code: "3000", amount_minor: -10_000 }
      ]
    )
    entry = Documents::Post.call(
      voucher, actor: "u:#{@org.user.id}", authorize: { user: @org.user }
    )
    ledger_event = LedgerEvent.find(entry.ledger_event_id)

    assert_equal @org.user.id, ledger_event.actor_user_id
    assert_equal domain_event.signing_key_id, ledger_event.signing_key_id
    assert EventSigning.verify(ledger_event)
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]
    assert DomainEvent.verify_chain(@org.tenant.id)[:ok]
  end

  test "verification rejects altered signature bytes or a mismatched actor" do
    event = DomainEvents::Record.call(
      tenant_id: @org.tenant.id, kind: "member.joined",
      actor: "u:#{@org.user.id}", actor_user_id: @org.user.id,
      payload: { "userId" => @org.user.id }
    )
    assert EventSigning.verify(event)

    event.signature = "not-a-valid-signature"
    refute EventSigning.verify(event)
    event.reload
    other = Onboarding::SignUp.call(
      email: "wrong-signer@folio.invalid", password: "correct-horse-battery", org_name: "Wrong Signer"
    )
    event.actor_user_id = other.user.id
    refute EventSigning.verify(event)
  end
end
