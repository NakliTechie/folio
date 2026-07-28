# frozen_string_literal: true

module Posting
  # Raised when a post targets a closed period. Own file so Zeitwerk autoloads it
  # independently of PostEntry.
  class PeriodClosedError < StandardError; end
end
