# frozen_string_literal: true

require "json"
require "securerandom"

module Folio
  # Repeatable application-level baseline for the governed posting and reporting paths.
  # All generated rows live in one transaction that is rolled back after measurements.
  module PerformanceBaseline
    module_function

    BASE_DATE = Date.new(2025, 4, 1)
    ACCOUNT_PAIRS = [
      %w[1000 4000],
      %w[1200 4000],
      %w[5000 1010],
      %w[5100 2000]
    ].freeze

    def call
      entry_count = bounded_integer("FOLIO_PERF_ENTRIES", default: 1_000, range: 1..100_000)
      report_runs = bounded_integer("FOLIO_PERF_REPORT_RUNS", default: 5, range: 1..50)
      result = nil

      ActiveRecord::Base.transaction do
        org = Onboarding::SignUp.call(
          email: "performance-baseline-#{SecureRandom.hex(8)}@folio.invalid",
          password: SecureRandom.base64(24),
          org_name: "Performance Baseline"
        )
        result = measure_tenant(org, entry_count: entry_count, report_runs: report_runs)
        raise ActiveRecord::Rollback
      end

      enforce_budgets!(result)
      puts JSON.pretty_generate(result)
    end

    def measure_tenant(org, entry_count:, report_runs:)
      tenant = org.tenant
      posting_ms = elapsed_ms do
        ActiveRecord::Base.uncached do
          entry_count.times { |index| post_document!(org, index) }
        end
      end
      counts = {
        documents: Document.where(tenant_id: tenant.id).count,
        events: LedgerEvent.where(tenant_id: tenant.id).count,
        entries: Entry.where(tenant_id: tenant.id).count,
        entry_lines: EntryLine.where(tenant_id: tenant.id).count,
        amounts: JournalEntryLineAmount.where(tenant_id: tenant.id).count
      }
      reports = report_measurements(tenant.id, runs: report_runs)
      chain = samples(report_runs) { LedgerEvent.verify_chain(tenant.id) }
      rebuild = samples(1) { Posting.rebuild!(tenant.id) }
      post_rebuild_trial_balance = samples(report_runs) { Reports.trial_balance(tenant.id) }

      {
        generated_at: Time.now.utc.iso8601,
        environment: Rails.env,
        ruby: RUBY_VERSION,
        rails: Rails.version,
        rolled_back: true,
        volume: counts.merge(requested_documents: entry_count, report_runs: report_runs),
        measurements_ms: {
          post_documents: summarize([ posting_ms ]),
          reports: reports,
          verify_event_chain: chain,
          rebuild_projection: rebuild,
          post_rebuild_trial_balance: post_rebuild_trial_balance
        }
      }
    end

    def post_document!(org, index)
      debit_code, credit_code = ACCOUNT_PAIRS.fetch(index % ACCOUNT_PAIRS.size)
      date = BASE_DATE + (index % 365)
      amount = 10_000 + (index % 10_000)
      document = Documents::BuildDraft.call(
        tenant: org.tenant,
        doc_type: "JV",
        document_date: date,
        posting_date: date,
        narration: "Performance baseline #{index + 1}",
        lines: [
          { account_code: debit_code, amount_minor: amount },
          { account_code: credit_code, amount_minor: -amount }
        ]
      )
      Documents::Post.call(document, actor: "benchmark:#{org.user.id}")
    end

    def report_measurements(tenant_id, runs:)
      warm_reports(tenant_id)
      {
        trial_balance: samples(runs) { Reports.trial_balance(tenant_id) },
        account_type_totals: samples(runs) { Reports.account_type_totals(tenant_id) },
        profit_and_loss: samples(runs) do
          Reports.profit_and_loss(tenant_id, from_date: BASE_DATE, to_date: BASE_DATE.next_year - 1)
        end,
        balance_sheet: samples(runs) { Reports.balance_sheet(tenant_id, as_of: BASE_DATE.next_year - 1) },
        day_book: samples(runs) do
          Reports.day_book(tenant_id, from_date: BASE_DATE, to_date: BASE_DATE.next_year - 1)
        end
      }
    end

    def warm_reports(tenant_id)
      Reports.trial_balance(tenant_id)
      Reports.account_type_totals(tenant_id)
      Reports.profit_and_loss(tenant_id, from_date: BASE_DATE, to_date: BASE_DATE.next_year - 1)
      Reports.balance_sheet(tenant_id, as_of: BASE_DATE.next_year - 1)
      Reports.day_book(tenant_id, from_date: BASE_DATE, to_date: BASE_DATE.next_year - 1)
    end

    def samples(count)
      values = Array.new(count) { elapsed_ms { ActiveRecord::Base.uncached { yield } } }
      summarize(values)
    end

    def elapsed_ms
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1_000
    end

    def summarize(values)
      ordered = values.sort
      {
        samples: values.size,
        min: ordered.first.round(2),
        median: percentile(ordered, 0.5).round(2),
        max: ordered.last.round(2)
      }
    end

    def percentile(ordered, fraction)
      ordered.fetch(((ordered.size - 1) * fraction).round)
    end

    def bounded_integer(name, default:, range:)
      value = Integer(ENV.fetch(name, default).to_s, 10)
      return value if range.cover?(value)

      abort "#{name} must be between #{range.begin} and #{range.end}"
    rescue ArgumentError
      abort "#{name} must be an integer"
    end

    def enforce_budgets!(result)
      measurements = flatten_measurements(result.fetch(:measurements_ms))
      failures = measurements.filter_map do |name, measurement|
        environment_name = "FOLIO_PERF_BUDGET_#{name.upcase}_MS"
        next unless ENV.key?(environment_name)

        budget = Float(ENV.fetch(environment_name))
        next if measurement.fetch(:median) <= budget

        "#{name} median #{measurement.fetch(:median)}ms exceeds #{budget}ms"
      rescue ArgumentError
        abort "#{environment_name} must be a number"
      end
      abort "Performance budget failed: #{failures.join('; ')}" if failures.any?
    end

    def flatten_measurements(measurements)
      measurements.each_with_object({}) do |(name, value), result|
        if value.key?(:median)
          result[name.to_s] = value
        else
          value.each { |child_name, child| result["#{name}_#{child_name}"] = child }
        end
      end
    end
  end
end

Folio::PerformanceBaseline.call
