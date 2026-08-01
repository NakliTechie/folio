# frozen_string_literal: true

module ForeignExchange
  module Revalue
    GAIN_ACCOUNT = "4100"
    LOSS_ACCOUNT = "5200"
    NotPermitted = Class.new(StandardError)

    module_function

    def call(tenant:, actor:, revaluation_date:, mode:, idempotency_key:)
      date = parse_date!(revaluation_date)
      selected_mode = mode.to_s
      raise ArgumentError, "revaluation mode must be simulate or post" unless %w[simulate post].include?(selected_mode)

      entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      office = Office.find_by!(tenant_id: tenant.id, entity_id: entity.id, code: "PRIMARY")
      authorize!(tenant, office, actor)
      run = find_or_create_run!(tenant, entity, office, actor, date, selected_mode, idempotency_key)
      return run if %w[simulated posted].include?(run.status)

      process!(run, tenant, entity, office, actor, date, selected_mode)
    rescue StandardError => e
      run&.update_columns(
        status: "failed", error_message: e.message.truncate(255),
        finished_at: Time.current, updated_at: Time.current
      ) unless %w[simulated posted].include?(run&.status)
      raise
    end

    def find_or_create_run!(tenant, entity, office, actor, date, mode, key)
      ExchangeRevaluationRun.find_or_create_by!(tenant_id: tenant.id, idempotency_key: key.to_s) do |run|
        run.entity = entity
        run.office = office
        run.created_by = actor
        run.revaluation_date = date
        run.mode = mode
      end.tap do |run|
        unless run.revaluation_date == date && run.mode == mode
          raise ArgumentError, "the idempotency key already belongs to another revaluation run"
        end
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def process!(run, tenant, entity, office, actor, date, mode)
      ExchangeRevaluationRun.transaction do
        run.lock!
        return run if %w[simulated posted].include?(run.status)

        if mode == "post"
          LedgerEvent.acquire_tenant_lock!(tenant.id)
          later = ExchangeRevaluationRun.where(
            tenant_id: tenant.id, entity_id: entity.id, status: "posted"
          ).where("revaluation_date > ?", date).minimum(:revaluation_date)
          if later
            raise ArgumentError,
              "revaluations must be posted chronologically; a later run already exists on #{later}"
          end
        end
        run.exchange_revaluation_items.delete_all
        position_rows(tenant, entity, date).each do |position|
          build_item!(run, tenant, date, position)
        end
        differences = run.exchange_revaluation_items.sum(:difference_minor)
        absolute = run.exchange_revaluation_items.sum("ABS(difference_minor)")
        event = post!(run, tenant, entity, office, actor, date) if mode == "post" && absolute.positive?
        status = mode == "simulate" ? "simulated" : "posted"
        run.update!(
          status: status, ledger_event: event, finished_at: Time.current,
          result: {
            "positionCount" => run.exchange_revaluation_items.count,
            "netDifferenceMinor" => differences,
            "absoluteDifferenceMinor" => absolute,
            "functionalCurrency" => entity.functional_currency
          }
        )
        run
      end
    end

    def position_rows(tenant, entity, date)
      transaction_join = <<~SQL.squish
        JOIN journal_entry_line_amounts fx_transaction
          ON fx_transaction.entry_line_id = entry_lines.id
         AND fx_transaction.slot_role = 'transaction'
      SQL
      functional_join = <<~SQL.squish
        JOIN journal_entry_line_amounts fx_functional
          ON fx_functional.entry_line_id = entry_lines.id
         AND fx_functional.slot_role = 'functional'
      SQL
      account_join = <<~SQL.squish
        JOIN accounts fx_accounts
          ON fx_accounts.tenant_id = entry_lines.tenant_id
         AND fx_accounts.code = entry_lines.account_code
         AND fx_accounts.monetary = TRUE
      SQL
      EntryLine.joins(:entry).joins(transaction_join).joins(functional_join).joins(account_join)
        .where(entry_lines: { tenant_id: tenant.id, entity_id: entity.id })
        .where(entries: { posting_date: ..date })
        .where.not("fx_transaction.currency = ?", entity.functional_currency)
        .group("entry_lines.account_code", "fx_transaction.currency")
        .pluck(
          Arel.sql("entry_lines.account_code"), Arel.sql("fx_transaction.currency"),
          Arel.sql("SUM(fx_transaction.amount_minor)"),
          Arel.sql("SUM(fx_functional.amount_minor)")
        )
    end

    def build_item!(run, tenant, date, position)
      account_code, foreign_currency, foreign_balance, historical_functional = position
      translation = ForeignExchange.translate(
        tenant_id: tenant.id, amount_minor: foreign_balance,
        from_currency: foreign_currency, to_currency: run.entity.functional_currency,
        on: date, rate_type: "closing"
      )
      prior_adjustments = ExchangeRevaluationItem.joins(:exchange_revaluation_run).where(
        tenant_id: tenant.id, account_code: account_code, foreign_currency: foreign_currency,
        exchange_revaluation_runs: { status: "posted", revaluation_date: ..date }
      ).sum(:difference_minor)
      carrying = historical_functional + prior_adjustments
      run.exchange_revaluation_items.create!(
        tenant_id: tenant.id, account_code: account_code,
        foreign_currency: foreign_currency, foreign_balance_minor: foreign_balance,
        carrying_functional_minor: carrying,
        target_functional_minor: translation.amount_minor,
        difference_minor: translation.amount_minor - carrying,
        applied_rate: translation.rate, exchange_rate: translation.exchange_rate
      )
    end

    def post!(run, tenant, entity, office, actor, date)
      ledger = Ledger.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      exponent = CurrencyProfile.exponent_for!(entity.functional_currency)
      lines = []
      run.exchange_revaluation_items.order(:account_code, :foreign_currency).each do |item|
        next if item.difference_minor.zero?

        extra = {
          "exchangeRevaluationRunId" => run.id,
          "foreignCurrency" => item.foreign_currency,
          "foreignBalanceMinor" => item.foreign_balance_minor,
          "exchangeRateId" => item.exchange_rate_id,
          "closingRate" => item.applied_rate.to_s("F")
        }
        lines << line(lines.size + 1, item.account_code, item.difference_minor,
          ledger, entity, office, exponent, extra)
        offset_code = item.difference_minor.positive? ? GAIN_ACCOUNT : LOSS_ACCOUNT
        lines << line(lines.size + 1, offset_code, -item.difference_minor,
          ledger, entity, office, exponent, extra)
      end
      entry = Posting::PostEntry.post!(
        tenant_id: tenant.id, entity_id: entity.id, office_id: office.id,
        actor: "u:#{actor.id}", actor_user_id: actor.id, origin: "folio",
        document_date: date, posting_date: date, entered_at: Time.current,
        fiscal_year: Documents.fiscal_year(date, variant: entity.fiscal_year_variant),
        period_no: Documents.period_no(date, variant: entity.fiscal_year_variant),
        authority: Authorization.authority_for(
          user: actor, tenant_id: tenant.id, office_id: office.id
        ),
        capabilities: capabilities_for(tenant, office, actor), lines: lines
      )
      LedgerEvent.find(entry.ledger_event_id)
    end

    def line(number, account_code, value, ledger, entity, office, exponent, extra)
      {
        line_no: number, account_code: account_code, ledger_id: ledger.id,
        entity_id: entity.id, office_id: office.id, extra: extra,
        amounts: [ {
          slot_role: "transaction", currency: entity.functional_currency,
          minor_unit_exponent: exponent, amount_minor: value
        } ]
      }
    end

    def authorize!(tenant, office, actor)
      return if Authorization.permits?(
        user: actor, tenant_id: tenant.id, office_id: office.id,
        capability: "currency.post"
      )

      raise NotPermitted, "not permitted to post foreign-currency revaluation"
    end

    def capabilities_for(tenant, office, actor)
      Authorization.role_for(user: actor, tenant_id: tenant.id, office_id: office.id)
        &.role_template&.role_permissions&.pluck(:capability) || []
    end

    def parse_date!(value)
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    rescue Date::Error
      raise ArgumentError, "revaluation date must be a valid ISO date"
    end
  end
end
