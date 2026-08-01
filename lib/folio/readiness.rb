# frozen_string_literal: true

module Folio
  module Readiness
    module_function

    def call(include_auxiliary: Rails.env.production?)
      checks = { primary: -> { probe!(ActiveRecord::Base.connection, "ledger_events") } }
      if include_auxiliary
        checks[:queue] = -> { probe!(SolidQueue::Record.connection, "solid_queue_jobs") }
        checks[:cache] = -> { probe!(SolidCache::Record.connection, "solid_cache_entries") }
      end

      failures = checks.filter_map do |name, check|
        check.call
        nil
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { readiness_check: name })
        name
      end
      {
        status: failures.empty? ? "ok" : "unavailable",
        checks: checks.keys,
        unavailable: failures
      }
    end

    def probe!(connection, required_table)
      connection.select_value("SELECT 1")
      raise "required database schema is unavailable" unless connection.data_source_exists?(required_table)
    end
  end
end
