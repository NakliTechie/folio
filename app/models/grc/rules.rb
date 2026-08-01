# frozen_string_literal: true

module Grc
  module Rules
    DEFAULTS = [
      [ "PROCUREMENT_APPROVAL", "Procurement maintenance and approval", "critical",
        "procurement.manage", "procurement.approve",
        "One person can create or change a vendor or order and approve it.",
        "Separate procurement preparation from vendor and order approval." ],
      [ "VENDOR_PAYMENT", "Vendor maintenance and payment", "critical",
        "procurement.manage", "payments.create",
        "One person can introduce a vendor and execute a payment to it.",
        "Remove one capability; this phantom-vendor path should not be mitigated indefinitely." ],
      [ "BILL_PAYMENT", "Bill entry and payment", "critical",
        "bills.create", "payments.create",
        "One person can enter a supplier liability and pay it.",
        "Separate accounts-payable entry from cash disbursement." ],
      [ "PROCUREMENT_RECEIPT", "Procurement maintenance and receipt", "high",
        "procurement.manage", "procurement.receive",
        "One person can raise an order and attest that goods or services arrived.",
        "Assign receipt or service acceptance to an independent operator." ],
      [ "BANK_RECONCILIATION", "Bank maintenance and reconciliation", "high",
        "banking.manage", "banking.reconcile",
        "One person can change bank evidence and certify the reconciliation.",
        "Separate statement handling from final reconciliation." ],
      [ "COA_POSTING", "Chart maintenance and posting", "high",
        "accounts.manage", "documents.post",
        "One person can create an account and post to it.",
        "Review account changes independently or separate master-data maintenance." ],
      [ "PERIOD_POSTING", "Period control and posting", "high",
        "period.lock", "documents.post",
        "One person can reopen or restrict a period and post into it.",
        "Assign period control to the controller or auditor role." ],
      [ "CONTRACT_APPROVAL", "Contract maintenance and approval", "high",
        "contracts.manage", "contracts.approve",
        "One person can set governed contract terms and approve them.",
        "Use an independent contract approver." ],
      [ "CONTRACT_POSTING", "Contract approval and accounting", "medium",
        "contracts.approve", "contracts.post",
        "One person can approve commercial terms and recognize their accounting effect.",
        "Review contract-generated postings independently." ],
      [ "ASSET_POSTING", "Asset maintenance and capitalization", "high",
        "assets.manage", "assets.post",
        "One person can create asset terms and capitalize them.",
        "Separate asset-master custody from capitalization and retirement posting." ],
      [ "CURRENCY_POSTING", "Rate maintenance and FX posting", "high",
        "currency.manage", "currency.post",
        "One person can set exchange rates and post revaluation from them.",
        "Approve rate sources independently from revaluation execution." ],
      [ "INVENTORY_POSTING", "Inventory setup and movement posting", "high",
        "inventory.manage", "inventory.post",
        "One person can configure stock masters and post stock movements.",
        "Separate inventory-master changes from warehouse posting." ],
      [ "CONTROLLING_ALLOCATION", "Controlling setup and allocation", "medium",
        "controlling.manage", "controlling.allocate",
        "One person can define allocation logic and execute it.",
        "Review cycles independently before allocation." ],
      [ "CONSOLIDATION_POSTING", "Group setup and elimination posting", "high",
        "consolidation.manage", "consolidation.post",
        "One person can change the group boundary and post eliminations.",
        "Separate group-structure maintenance from elimination posting." ],
      [ "ROLE_FINANCE", "Access administration and financial posting", "critical",
        "users.manage", "documents.post",
        "One person can grant authority and use financial posting authority.",
        "Keep access administration independent or perform frequent owner recertification." ]
    ].freeze

    module_function

    def seed_for!(tenant)
      DEFAULTS.each do |code, name, severity, capability_a, capability_b, description, remediation|
        rule = SodConflictRule.find_or_initialize_by(tenant_id: tenant.id, code: code)
        rule.update!(
          name: name, severity: severity, capability_a: capability_a, capability_b: capability_b,
          description: description, remediation: remediation, active: true
        )
      end
    end
  end
end
