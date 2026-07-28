# frozen_string_literal: true

module Posting
  # Raised when a post targets a restricted period without the required capability. Own file
  # so Zeitwerk autoloads it independently of PostEntry.
  class PeriodRestrictedError < StandardError; end
end
