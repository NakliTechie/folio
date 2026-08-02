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
      "contract.updated"    => "A draft contract's governed terms or evidence were updated.",
      "contract.signed"     => "A contract was signed by the counterparties.",
      "contract.activated"  => "A signed contract became active (obligations begin).",
      "contract.amended"    => "An active contract was amended.",
      "contract.closed"     => "A contract reached the end of its lifecycle.",
      "contract.performance_obligation_added" => "A performance obligation was identified.",
      "contract.milestone_added" => "A recognition or billing milestone was identified.",
      "contract.milestone_achieved" => "A governed contract milestone was achieved.",
      "contract.transaction_price_allocated" => "The transaction price was allocated to obligations.",
      "contract.revenue_schedule_generated" => "A versioned revenue schedule was generated.",

      # --- fixed assets (Batch 9) ---
      "asset.created" => "A fixed-asset component and its valuation terms were created.",
      "asset.acquired" => "A fixed asset was capitalized into its book and tax valuations.",
      "asset.retired" => "A fixed asset was retired and its carrying amounts were cleared.",

      # --- bank reconciliation (Batch 9) ---
      "bank_statement.imported" => "A bank statement was imported with a source fingerprint.",
      "bank_statement.auto_matched" => "Unambiguous bank lines were matched automatically.",
      "bank_statement.line_matched" => "A bank line was matched by an authorized user.",
      "bank_statement.line_ignored" => "A bank line was explicitly excluded with a reason.",
      "bank_statement.reconciled" => "A complete bank statement was reconciled and closed.",

      # --- procurement / vendor management (Batch 9) ---
      "purchase_order.raised"   => "A purchase order was raised.",
      "purchase_order.approved" => "A purchase order was approved for release.",
      "purchase_order.received" => "Ordered goods or services were accepted against a purchase order.",
      "purchase_order.closed"   => "A purchase order was closed.",
      "vendor.onboarded"        => "A vendor completed onboarding.",
      "vendor.approved"         => "A vendor was independently approved for procurement.",
      "vendor.suspended"        => "A vendor was suspended.",

      # --- governance, risk & access recertification (Batch 9) ---
      "access_review.captured" => "An immutable access and SoD review snapshot was captured.",
      "access_review.attested" => "An owner attested a captured access review.",

      # --- open .khata interoperability (Batch 9) ---
      "khata.imported" => "A verified .khata chain and ledger projection were imported.",
      "khata.exported" => "A portable .khata copy was exported.",

      # --- India e-invoice lifecycle (statutory, non-financial) ---
      "einvoice.prepared"      => "An immutable INV-01 request was prepared.",
      "einvoice.acknowledged"  => "An IRP acknowledged a document and returned an IRN.",
      "einvoice.rejected"      => "An IRP rejected an e-invoice request.",
      "einvoice.indeterminate" => "An IRP attempt ended without a conclusive response.",
      "einvoice.cancellation_prepared" => "An immutable IRN cancellation request was prepared.",
      "einvoice.cancelled" => "An IRP conclusively cancelled an IRN.",
      "einvoice.cancellation_rejected" => "An IRP rejected an IRN cancellation request.",
      "einvoice.cancellation_indeterminate" => "An IRN cancellation ended without a conclusive response.",
      "einvoice.cancellation_reconciled_active" => "IRP reconciliation confirmed that an IRN remains active.",
      # --- India e-way bill lifecycle through the IRN boundary ---
      "eway_bill.prepared" => "An immutable EWB transport request was included for IRN generation.",
      "eway_bill.generated" => "An IRP returned a governed e-way bill number and validity window.",

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
