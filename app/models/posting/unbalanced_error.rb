# frozen_string_literal: true

module Posting
  # Raised when an entry does not balance within some (ledger, slot_role, currency) slice.
  # In its own file so Zeitwerk autoloads it independently of Posting::PostEntry.
  class UnbalancedError < StandardError
    attr_reader :offenders

    def initialize(offenders)
      @offenders = offenders
      pretty = offenders.map { |(l, s, c), sum| "ledger=#{l} #{s}/#{c} sums to #{sum}" }.join("; ")
      super("entry does not balance per (ledger, slot, currency): #{pretty}")
    end
  end
end
