# frozen_string_literal: true

module Posting
  module Rules
    # Opening balances post through the ordinary ledger engine. Their semantic difference is
    # period 0, resolved by Documents.period_no_for at post time.
    class OpeningBalance < JournalVoucher
    end
  end
end
