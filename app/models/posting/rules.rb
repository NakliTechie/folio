# frozen_string_literal: true

module Posting
  # The posting-rule registry. A document type names its rule; the rule turns a document into
  # the balanced entry-line array PostEntry.post! consumes. This is the seam that keeps the
  # posting core ignorant of what an invoice (or a JV, or a payment) IS.
  module Rules
    UnknownRule = Class.new(StandardError)

    REGISTRY = {
      "journal_voucher" => "Posting::Rules::JournalVoucher",
      "opening_balance" => "Posting::Rules::OpeningBalance",
      "sales_invoice" => "Posting::Rules::SalesInvoice",
      "credit_note" => "Posting::Rules::CreditNote"
    }.freeze

    def self.for(identifier)
      name = REGISTRY.fetch(identifier) { raise UnknownRule, "no posting rule '#{identifier}'" }
      name.constantize
    end
  end
end
