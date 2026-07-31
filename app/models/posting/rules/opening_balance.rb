# frozen_string_literal: true

module Posting
  module Rules
    # Opening balances post through the ordinary ledger engine. Their semantic difference is
    # period 0, resolved by Documents.period_no_for at post time.
    class OpeningBalance < JournalVoucher
      def self.validate_document!(document)
        super
        return if document.reverses_document_id.present?

        codes = document.document_lines.map(&:account_code)
        invalid = Account.where(tenant_id: document.tenant_id, code: codes)
          .where.not(account_type: %w[asset liability equity]).pluck(:code)
        return if invalid.empty?

        raise Documents::InvalidDocument,
          "opening balances may use only asset, liability, and equity accounts: #{invalid.join(', ')}"
      end
    end
  end
end
