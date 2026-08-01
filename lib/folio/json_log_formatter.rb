# frozen_string_literal: true

require "json"

module Folio
  class JsonLogFormatter < Logger::Formatter
    def call(severity, time, program_name, message)
      payload = {
        timestamp: time.utc.iso8601(6),
        severity: severity,
        program: program_name,
        message: message.is_a?(String) ? message : message.inspect
      }.compact
      "#{JSON.generate(payload)}\n"
    end
  end
end
