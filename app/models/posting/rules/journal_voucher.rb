# frozen_string_literal: true

module Posting
  module Rules
    # The simplest posting rule: a journal voucher maps each document line 1:1 to a ledger
    # entry line on the PRIMARY ledger, no tax, no split. It exercises the whole
    # document→rule→post loop; richer rules (invoices computing tax/splits) plug in the same way.
    class JournalVoucher
      def self.entry_lines(document)
        ledger = Ledger.find_by!(tenant_id: document.tenant_id, code: "PRIMARY")
        # A reversal keeps the SAME account with a negated amount (a negative posting, not a
        # counter-posting to the opposite side) — and it MUST be flagged is_negative_posting so a
        # turnover report can reduce the original side rather than inflate the opposite one. Per
        # §7 that distinction is unrecoverable from the amounts alone once on the append-only log.
        negative = document.reverses_document_id.present?
        document.document_lines.map do |dl|
          line = {
            line_no: dl.line_no, account_code: dl.account_code, ledger_id: ledger.id,
            entity_id: document.entity_id, office_id: document.office_id,
            amounts: [ {
              slot_role: "transaction", currency: dl.currency,
              minor_unit_exponent: dl.minor_unit_exponent, amount_minor: dl.amount_minor
            } ]
          }
          line[:is_negative_posting] = true if negative
          line
        end
      end
    end
  end
end
