# frozen_string_literal: true

module Contracts
  module RunRevenueRecognition
    CONTRACT_ASSET_ACCOUNT = "1190"
    CONTRACT_LIABILITY_ACCOUNT = "2200"
    MODES = %w[simulate post].freeze

    NotPermitted = Class.new(StandardError)

    module_function

    def call(contract:, actor:, posting_date:, mode:, idempotency_key:)
      date = parse_date!(posting_date)
      selected_mode = mode.to_s
      raise InvalidContract, "posting-run mode must be simulate or post" unless MODES.include?(selected_mode)
      authorize!(contract, actor)
      assert_accounts!(contract)

      run = find_or_create_run!(contract, actor, date, selected_mode, idempotency_key)
      return run if %w[simulated posted].include?(run.status)

      process!(run, contract, actor, date, selected_mode)
    rescue StandardError => e
      run&.update_columns(
        status: "failed", error_message: e.message.truncate(255), finished_at: Time.current,
        updated_at: Time.current
      ) unless %w[simulated posted].include?(run&.status)
      raise
    end

    def find_or_create_run!(contract, actor, date, mode, key)
      ContractPostingRun.find_or_create_by!(
        tenant_id: contract.tenant_id, idempotency_key: key.to_s
      ) do |run|
        run.office = contract.office
        run.contract = contract
        run.created_by = actor
        run.mode = mode
        run.posting_date = date
      end.tap do |run|
        unless run.contract_id == contract.id && run.mode == mode && run.posting_date == date
          raise InvalidContract, "the idempotency key already belongs to a different posting run"
        end
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def process!(run, contract, actor, date, mode)
      ContractPostingRun.transaction do
        run.lock!
        run.update!(status: "running", started_at: Time.current, error_message: nil)
        lines = due_lines(contract, date).lock.to_a
        recognized_before = posted_recognition(contract, date)
        billed = posted_billing(contract, date)
        counts = Hash.new(0)

        lines.each do |line|
          item = run.contract_posting_run_items.find_or_initialize_by(
            tenant_id: contract.tenant_id, contract_schedule_line: line
          )
          if line.amount_minor.zero?
            item.update!(status: "skipped", error_message: "zero-value schedule line")
            counts[:skipped] += 1
            next
          end
          unless milestone_ready?(line, date)
            item.update!(status: "skipped", error_message: "milestone achievement evidence is pending")
            counts[:blocked] += 1
            next
          end

          split = recognition_split(
            amount: line.amount_minor, billed: billed, recognized_before: recognized_before
          )
          if mode == "simulate"
            item.update!(status: "simulated")
            counts[:simulated] += 1
          else
            event = post_line!(line, contract, actor, date, split)
            line.update!(status: "posted", posted_ledger_event: event, posted_at: Time.current)
            item.update!(status: "posted", ledger_event: event)
            counts[:posted] += 1
          end
          recognized_before += line.amount_minor
          counts[:contract_liability_minor] += split.fetch(:contract_liability_minor)
          counts[:contract_asset_minor] += split.fetch(:contract_asset_minor)
          counts[:revenue_minor] += line.amount_minor
        end

        status = mode == "simulate" ? "simulated" : "posted"
        run.update!(
          status: status, finished_at: Time.current,
          result: counts.stringify_keys.merge(
            "billedThroughPostingDateMinor" => billed,
            "recognizedBeforeRunMinor" => posted_recognition(contract, date)
          )
        )
        run
      end
    end

    def due_lines(contract, date)
      ContractScheduleLine.joins(:contract_schedule)
        .merge(contract.contract_schedules.current)
        .where(tenant_id: contract.tenant_id, status: "planned", due_date: ..date)
        .includes(:contract_milestone, contract_schedule: :contract_performance_obligation)
        .order(:due_date, :id)
    end

    def posted_billing(contract, date)
      invoices = Document.where(
        tenant_id: contract.tenant_id, contract_id: contract.id,
        doc_type: "SI", state: "posted", reverses_document_id: nil,
        posting_date: ..date
      ).sum(:subtotal_minor)
      credits = Document.where(
        tenant_id: contract.tenant_id, contract_id: contract.id,
        doc_type: "CN", state: "posted", posting_date: ..date
      ).sum(:subtotal_minor)
      invoices - credits
    end

    def posted_recognition(contract, date)
      ContractScheduleLine.joins(:contract_schedule)
        .where(
          tenant_id: contract.tenant_id,
          contract_schedules: { contract_id: contract.id },
          status: "posted", due_date: ..date
        ).sum(:amount_minor)
    end

    def milestone_ready?(line, date)
      milestone = line.contract_milestone
      return true unless milestone
      return false unless milestone.status == "achieved" && milestone.achieved_date <= date

      !milestone.acceptance_required? || milestone.acceptance_date&.<=(date)
    end

    def recognition_split(amount:, billed:, recognized_before:)
      liability_available = [ billed - recognized_before, 0 ].max
      liability = [ amount, liability_available ].min
      {
        contract_liability_minor: liability,
        contract_asset_minor: amount - liability
      }
    end

    def post_line!(line, contract, actor, posting_date, split)
      schedule = line.contract_schedule
      obligation = schedule.contract_performance_obligation
      ledger = Ledger.find_by!(tenant_id: contract.tenant_id, code: "PRIMARY")
      exponent = CurrencyProfile.exponent_for!(contract.currency)
      amount = lambda do |value|
        {
          slot_role: "transaction", currency: contract.currency,
          minor_unit_exponent: exponent, amount_minor: value
        }
      end
      extra = {
        "contractId" => contract.id, "contractNumber" => contract.contract_number,
        "performanceObligationId" => obligation.id,
        "performanceObligationNo" => obligation.obligation_no,
        "scheduleId" => schedule.id, "scheduleVersion" => schedule.version,
        "scheduleLineId" => line.id, "allocationRunId" => schedule.contract_allocation_line.contract_allocation_run_id
      }
      lines = []
      if split[:contract_liability_minor].positive?
        lines << posting_line(lines.length + 1, CONTRACT_LIABILITY_ACCOUNT, contract, ledger,
          amount.call(split[:contract_liability_minor]), extra)
      end
      if split[:contract_asset_minor].positive?
        lines << posting_line(lines.length + 1, CONTRACT_ASSET_ACCOUNT, contract, ledger,
          amount.call(split[:contract_asset_minor]), extra)
      end
      lines << posting_line(lines.length + 1, line.revenue_account_code, contract, ledger,
        amount.call(-line.amount_minor), extra)

      entity = contract.entity
      entry = Posting::PostEntry.post!(
        tenant_id: contract.tenant_id, entity_id: contract.entity_id, office_id: contract.office_id,
        actor: "u:#{actor.id}", origin: "folio", document_date: posting_date,
        posting_date: posting_date, entered_at: Time.current,
        fiscal_year: Documents.fiscal_year(posting_date, variant: entity.fiscal_year_variant),
        period_no: Documents.period_no(posting_date, variant: entity.fiscal_year_variant),
        capabilities: capabilities_for(contract, actor),
        authority: Authorization.authority_for(
          user: actor, tenant_id: contract.tenant_id, office_id: contract.office_id
        ),
        lines: lines
      )
      LedgerEvent.find(entry.ledger_event_id)
    end

    def posting_line(number, account_code, contract, ledger, amount, extra)
      {
        line_no: number, account_code: account_code, ledger_id: ledger.id,
        entity_id: contract.entity_id, office_id: contract.office_id,
        party_id: contract.party_id, party_role: "customer", extra: extra,
        amounts: [ amount ]
      }
    end

    def authorize!(contract, actor)
      return if Authorization.permits?(
        user: actor, tenant_id: contract.tenant_id, capability: "contracts.post",
        office_id: contract.office_id, amount_minor: contract.total_contract_value_minor
      )

      raise NotPermitted, "not permitted to post contract revenue (role or posting limit)"
    end

    def capabilities_for(contract, actor)
      Authorization.role_for(
        user: actor, tenant_id: contract.tenant_id, office_id: contract.office_id
      )&.role_template&.role_permissions&.pluck(:capability) || []
    end

    def assert_accounts!(contract)
      codes = [ CONTRACT_ASSET_ACCOUNT, CONTRACT_LIABILITY_ACCOUNT ] +
        contract.contract_performance_obligations.pluck(:revenue_account_code)
      available = Account.active.where(tenant_id: contract.tenant_id, code: codes.uniq).pluck(:code)
      missing = codes.uniq - available
      raise InvalidContract, "accounts unavailable for revenue posting: #{missing.join(', ')}" if missing.any?
    end

    def parse_date!(value)
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    rescue Date::Error
      raise InvalidContract, "posting date must be a valid ISO date"
    end
  end
end
