# frozen_string_literal: true

module DomainEvents
  # The registry of allowed domain-event kinds.
  #
  # A domain event's `action` is not free text: it must be one of these registered
  # lifecycle verbs. The registry is what keeps the non-financial log legible — a module
  # cannot quietly invent `contract.thing_happened`; a new kind is a deliberate, reviewed
  # addition here, the same way a new document type is a deliberate addition to its range.
  #
  # Namespaced `<entity>.<verb>`. Entities are the modules that layer on the accounting
  # kernel (Folio's real ambition beyond server-side books). The kinds below seed the two
  # modules the roadmap sequences first — contract management (Batch 6) and
  # vendor/procurement (Batch 9) — plus onboarding lifecycle. Add kinds as modules land;
  # never remove one that a stored event already carries (the log is append-only, and a
  # verify pass must still recognise historical kinds).
  module Kinds
    # kind => one-line human description (the description is documentation, not hashed).
    REGISTRY = {
      # --- contract management (Batch 6 beachhead) ---
      "contract.drafted"    => "A contract was created in draft.",
      "contract.signed"     => "A contract was signed by the counterparties.",
      "contract.activated"  => "A signed contract became active (obligations begin).",
      "contract.amended"    => "An active contract was amended.",
      "contract.closed"     => "A contract reached the end of its lifecycle.",

      # --- procurement / vendor management (Batch 9) ---
      "purchase_order.raised"   => "A purchase order was raised.",
      "purchase_order.approved" => "A purchase order was approved for release.",
      "purchase_order.closed"   => "A purchase order was closed.",
      "vendor.onboarded"        => "A vendor completed onboarding.",
      "vendor.suspended"        => "A vendor was suspended.",

      # --- tenant / membership lifecycle (non-financial governance) ---
      "member.invited"  => "A user was invited to join a tenant with a role.",
      "member.joined"   => "An invited user accepted and joined a tenant.",
      "member.removed"  => "A membership was revoked."
    }.freeze

    ALL = REGISTRY.keys.freeze

    module_function

    def valid?(kind)
      REGISTRY.key?(kind)
    end

    def describe(kind)
      REGISTRY[kind]
    end
  end
end
