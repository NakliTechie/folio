# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

module Folio
  # Two deliberately different measurements share this runner:
  #
  # - rollback_microbenchmark: fast, isolated journal-path comparison; no commit/fsync claim.
  # - committed_release: mixed business documents committed independently to an explicitly
  #   disposable database. The generated tenant is retained for inspection.
  #
  # Both assert the event chain and semantic projection/report equivalence across rebuild.
  module PerformanceBaseline
    module_function

    BASE_DATE = Date.new(2025, 4, 1)
    ACCOUNT_PAIRS = [
      %w[1000 4000],
      %w[1200 4000],
      %w[5000 1010],
      %w[5100 2000]
    ].freeze
    MODES = %w[rollback_microbenchmark committed_release].freeze

    def call
      mode = ENV.fetch("FOLIO_PERF_MODE", "rollback_microbenchmark")
      abort "FOLIO_PERF_MODE must be one of: #{MODES.join(', ')}" unless MODES.include?(mode)

      entry_count = bounded_integer("FOLIO_PERF_ENTRIES", default: 1_000, range: 1..100_000)
      report_runs = bounded_integer("FOLIO_PERF_REPORT_RUNS", default: 5, range: 1..50)
      result = mode == "committed_release" ? committed_release(entry_count, report_runs) :
        rollback_microbenchmark(entry_count, report_runs)

      enforce_budgets!(result)
      puts JSON.pretty_generate(result)
    end

    def rollback_microbenchmark(entry_count, report_runs)
      result = nil
      ActiveRecord::Base.transaction do
        org = create_organization("Rollback Microbenchmark")
        result = measure_tenant(
          org, entry_count: entry_count, report_runs: report_runs,
          workload: :journals, rolled_back: true
        )
        raise ActiveRecord::Rollback
      end
      result
    end

    def committed_release(entry_count, report_runs)
      database = ActiveRecord::Base.connection_db_config.database.to_s
      safe_name = database.include?("performance") || database.include?("release_baseline")
      confirmation = ENV["FOLIO_PERF_COMMITTED_CONFIRM"].to_s
      unless safe_name && ActiveSupport::SecurityUtils.secure_compare(confirmation, database)
        abort <<~MESSAGE.squish
          committed_release writes durable rows. Use a disposable database whose name contains
          performance or release_baseline and set FOLIO_PERF_COMMITTED_CONFIRM to that exact database name.
        MESSAGE
      end

      org = create_organization("Committed Release Baseline")
      measure_tenant(
        org, entry_count: entry_count, report_runs: report_runs,
        workload: :representative, rolled_back: false
      )
    end

    def create_organization(label)
      Onboarding::SignUp.call(
        email: "performance-baseline-#{SecureRandom.hex(8)}@folio.invalid",
        password: SecureRandom.base64(24),
        org_name: label
      )
    end

    def measure_tenant(org, entry_count:, report_runs:, workload:, rolled_back:)
      tenant = org.tenant
      masters = configure_representative_masters!(org) if workload == :representative
      open_items = { customer: [], vendor: [] }
      posting_ms = elapsed_ms do
        ActiveRecord::Base.uncached do
          entry_count.times do |index|
            if workload == :representative
              post_representative_document!(org, masters, open_items, index)
            else
              post_journal!(org, index)
            end
          end
        end
      end
      counts = projection_counts(tenant.id)
      reports = report_measurements(tenant.id, runs: report_runs)
      verification = nil
      chain = samples(report_runs) do
        verification = LedgerEvent.verify_chain(tenant.id)
        assert_chain!(verification)
      end

      before = correctness_snapshot(tenant.id)
      rebuild = samples(1) { Posting.rebuild!(tenant.id) }
      after = correctness_snapshot(tenant.id)
      assert_rebuild_equivalence!(before, after)
      post_rebuild_trial_balance = samples(report_runs) { Reports.trial_balance(tenant.id) }

      {
        generated_at: Time.now.utc.iso8601,
        environment: Rails.env,
        database: ActiveRecord::Base.connection_db_config.database,
        ruby: RUBY_VERSION,
        rails: Rails.version,
        mode: workload == :representative ? "committed_release" : "rollback_microbenchmark",
        rolled_back: rolled_back,
        retained_tenant_id: rolled_back ? nil : tenant.id,
        workload: workload == :representative ?
          "mixed committed journals, GST sales invoices, purchase bills, receipts, and payments" :
          "journal-only inside one rollback transaction; excludes commit/fsync cost",
        volume: counts.merge(requested_documents: entry_count, report_runs: report_runs),
        correctness: {
          event_chain: "verified",
          verified_events: verification.fetch(:rows),
          verified_head: verification[:head],
          projection_digest: after.fetch(:projection_digest),
          rebuild_equivalent: true
        },
        measurements_ms: {
          post_documents: summarize([ posting_ms ]),
          reports: reports,
          verify_event_chain: chain,
          rebuild_projection: rebuild,
          post_rebuild_trial_balance: post_rebuild_trial_balance
        }
      }
    end

    def configure_representative_masters!(org)
      tenant = org.tenant
      entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      office = Office.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      office.update!(
        address_line1: "1 Baseline Lane", city: "Mumbai", postal_code: "400001",
        state_code: "27", country_code: "IN"
      )
      registration = TaxRegistrations::Manage.create!(
        tenant: tenant, entity: entity,
        attributes: {
          kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
          valid_from: BASE_DATE
        },
        office_ids: [ office.id ], actor: org.user
      )
      customer = create_party!(org, "C-PERF", "Baseline Customer", "customer", "29AAAAA0300L1Z8")
      vendor = create_party!(org, "V-PERF", "Baseline Vendor", "vendor", "29ABCDE1234F1ZW")
      service = Items::Manage.create!(
        tenant: tenant,
        attributes: {
          code: "PERF-SVC", name: "Baseline service", item_type: "service",
          hsn_sac_code: "998311", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
          cess_rate_basis_points: 0, income_account_code: "4000", expense_account_code: "5000"
        },
        actor: org.user
      )
      { registration: registration, customer: customer, vendor: vendor, service: service }
    end

    def create_party!(org, number, name, role, identifier)
      Parties::Manage.create!(
        tenant: org.tenant,
        attributes: {
          party_number: number, name: name, state_code: "29", country_code: "IN",
          address_line1: "2 Counterparty Road", city: "Bengaluru", postal_code: "560001"
        },
        roles: [ role ],
        tax_registration_attributes: {
          kind: "GSTIN", identifier: identifier, valid_from: BASE_DATE
        },
        actor: org.user
      )
    end

    def post_representative_document!(org, masters, open_items, index)
      case index % 5
      when 0 then post_sales_invoice!(org, masters, open_items, index)
      when 1 then post_settlement!(org, open_items.fetch(:customer).shift, "RC", index) || post_journal!(org, index)
      when 2 then post_purchase_bill!(org, masters, open_items, index)
      when 3 then post_settlement!(org, open_items.fetch(:vendor).shift, "PY", index) || post_journal!(org, index)
      else post_journal!(org, index)
      end
    end

    def post_sales_invoice!(org, masters, open_items, index)
      date = baseline_date(index)
      document = SalesInvoices::BuildDraft.call(
        tenant: org.tenant, party_id: masters.fetch(:customer).id,
        tax_registration_id: masters.fetch(:registration).id,
        document_date: date, due_date: date + 30.days, place_of_supply_state_code: "29",
        external_reference: "PERF-SI-#{index + 1}",
        lines: [ { item_id: masters.fetch(:service).id, quantity: "1", unit_price: unit_price(index) } ],
        narration: "Committed baseline sale #{index + 1}"
      )
      post!(org, document, required_capability: "invoices.create")
      open_items.fetch(:customer) << open_item_for(document, "1200")
    end

    def post_purchase_bill!(org, masters, open_items, index)
      date = baseline_date(index)
      document = PurchaseBills::BuildDraft.call(
        tenant: org.tenant, party_id: masters.fetch(:vendor).id,
        tax_registration_id: masters.fetch(:registration).id,
        document_date: date, due_date: date + 30.days, place_of_supply_state_code: "29",
        external_reference: "PERF-PB-#{index + 1}",
        lines: [ { item_id: masters.fetch(:service).id, quantity: "1", unit_price: unit_price(index) } ],
        narration: "Committed baseline purchase #{index + 1}"
      )
      post!(org, document, required_capability: "bills.create")
      open_items.fetch(:vendor) << open_item_for(document, "2000")
    end

    def post_settlement!(org, target, doc_type, index)
      return unless target

      amount_minor = Posting::Clearing.open_amount(target)
      document = Settlements::BuildDraft.call(
        tenant: org.tenant, doc_type: doc_type, document_date: baseline_date(index),
        bank_account_code: "1010",
        allocations: [ {
          target_entry_line_id: target.id, amount: format("%.2f", amount_minor / 100.0),
          clearing_mode: "partial"
        } ],
        narration: "Committed baseline settlement #{index + 1}"
      )
      post!(org, document, required_capability: "settlements.create")
    end

    def post_journal!(org, index)
      debit_code, credit_code = ACCOUNT_PAIRS.fetch(index % ACCOUNT_PAIRS.size)
      date = baseline_date(index)
      amount = 10_000 + (index % 10_000)
      document = Documents::BuildDraft.call(
        tenant: org.tenant,
        doc_type: "JV",
        document_date: date,
        posting_date: date,
        narration: "Performance microbenchmark #{index + 1}",
        lines: [
          { account_code: debit_code, amount_minor: amount },
          { account_code: credit_code, amount_minor: -amount }
        ]
      )
      post!(org, document, required_capability: "documents.post")
    end

    def post!(org, document, required_capability:)
      Documents::Post.call(
        document, actor: "benchmark:#{org.user.id}", authorize: { user: org.user },
        required_capability: required_capability
      )
    end

    def open_item_for(document, account_code)
      Entry.find(document.reload.posted_entry_id).entry_lines.find_by!(account_code: account_code, open_item: true)
    end

    def baseline_date(index) = BASE_DATE + (index % 365)

    def unit_price(index) = format("%.2f", 100 + (index % 100))

    def projection_counts(tenant_id)
      {
        documents: Document.where(tenant_id: tenant_id).count,
        events: LedgerEvent.where(tenant_id: tenant_id).count,
        entries: Entry.where(tenant_id: tenant_id).count,
        entry_lines: EntryLine.where(tenant_id: tenant_id).count,
        amounts: JournalEntryLineAmount.where(tenant_id: tenant_id).count
      }
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
      report_snapshot(tenant_id)
    end

    def correctness_snapshot(tenant_id)
      {
        projection_digest: projection_digest(tenant_id),
        posted_document_bindings: Document.where(tenant_id: tenant_id, state: "posted")
          .where.not(posted_entry_id: nil).count,
        reports: report_snapshot(tenant_id)
      }
    end

    def report_snapshot(tenant_id)
      day_book = Reports.day_book(tenant_id, from_date: BASE_DATE, to_date: BASE_DATE.next_year - 1)
      day_book = day_book.merge(rows: day_book.fetch(:rows).map { |row| row.except(:entry_id) })
      {
        trial_balance: Reports.trial_balance(tenant_id),
        account_type_totals: Reports.account_type_totals(tenant_id),
        profit_and_loss: Reports.profit_and_loss(
          tenant_id, from_date: BASE_DATE, to_date: BASE_DATE.next_year - 1
        ),
        balance_sheet: Reports.balance_sheet(tenant_id, as_of: BASE_DATE.next_year - 1),
        day_book: day_book
      }
    end

    def projection_digest(tenant_id)
      digest = Digest::SHA256.new
      Entry.where(tenant_id: tenant_id).includes(entry_lines: :amounts)
        .order(:ledger_event_id, :id).find_each do |entry|
        canonical = {
          ledger_event_id: entry.ledger_event_id,
          document_id: entry.document_id,
          document_date: entry.document_date,
          posting_date: entry.posting_date,
          fiscal_year: entry.fiscal_year,
          period_no: entry.period_no,
          lines: entry.entry_lines.sort_by(&:line_no).map do |line|
            {
              line_no: line.line_no, account_code: line.account_code, ledger_id: line.ledger_id,
              line_class: line.line_class, party_id: line.party_id, party_role: line.party_role,
              open_item: line.open_item, cleared_on: line.cleared_on,
              cleared_amount_minor: line.cleared_amount_minor, source_event_id: line.source_event_id,
              amounts: line.amounts.sort_by(&:slot_role).map do |amount|
                [ amount.slot_role, amount.currency, amount.minor_unit_exponent, amount.amount_minor ]
              end
            }
          end
        }
        digest << JSON.generate(canonical)
      end
      digest.hexdigest
    end

    def assert_chain!(verification)
      return if verification.fetch(:ok)

      raise "event-chain verification failed at #{verification[:broken_at]}: #{verification[:reason]}"
    end

    def assert_rebuild_equivalence!(before, after)
      return if before == after

      differences = before.keys.reject { |key| before.fetch(key) == after.fetch(key) }
      raise "projection rebuild changed: #{differences.join(', ')}"
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
