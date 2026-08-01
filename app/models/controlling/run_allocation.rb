# frozen_string_literal: true

module Controlling
  module RunAllocation
    module_function

    def call(cycle:, actor:, attributes:)
      input = normalize!(cycle, attributes)
      authorize!(cycle, actor)

      AllocationRun.transaction do
        LedgerEvent.acquire_tenant_lock!(cycle.tenant_id)
        existing = AllocationRun.find_by(
          tenant_id: cycle.tenant_id, idempotency_key: input.fetch(:idempotency_key)
        )
        return assert_same!(existing, input) if existing
        raise InvalidControl, "allocation cycle is not effective on the through date" unless
          cycle.effective_on?(input.fetch(:through_date))

        amount = sender_balance(cycle, input.fetch(:period_start), input.fetch(:through_date))
        allocations = allocate_exactly(amount, cycle.allocation_receivers.order(:cost_center_id))
        event = post!(cycle, actor, input, allocations) if input.fetch(:mode) == "post" && amount.positive?
        run = AllocationRun.create!(
          tenant_id: cycle.tenant_id, allocation_cycle: cycle, created_by: actor,
          ledger_event: event, idempotency_key: input.fetch(:idempotency_key),
          request_sha256: input.fetch(:request_sha256), mode: input.fetch(:mode),
          status: input.fetch(:mode) == "post" ? "posted" : "simulated",
          period_start: input.fetch(:period_start), through_date: input.fetch(:through_date),
          posting_date: input.fetch(:posting_date), allocated_amount_minor: amount,
          result: result(cycle, allocations)
        )
        allocations.each do |receiver, receiver_amount|
          run.allocation_run_items.create!(
            tenant_id: cycle.tenant_id, sender_cost_center: cycle.sender_cost_center,
            receiver_cost_center: receiver.cost_center, account_code: cycle.source_account_code,
            weight_basis_points: receiver.weight_basis_points, amount_minor: receiver_amount
          ) if receiver_amount.positive?
        end
        run
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def normalize!(cycle, attributes)
      through = parse_date(value(attributes, :through_date), "through date")
      fiscal_year = Documents.fiscal_year(through, variant: cycle.entity.fiscal_year_variant)
      input = {
        period_start: PeriodControls::Calendar.date_range(
          entity: cycle.entity, fiscal_year: fiscal_year,
          period_no: Documents.period_no(through, variant: cycle.entity.fiscal_year_variant)
        ).first,
        through_date: through,
        posting_date: parse_date(value(attributes, :posting_date), "posting date"),
        mode: value(attributes, :mode).to_s,
        idempotency_key: value(attributes, :idempotency_key).to_s.strip
      }
      raise InvalidControl, "mode must be simulate or post" unless %w[simulate post].include?(input[:mode])
      raise InvalidControl, "idempotency key is required" if input[:idempotency_key].blank?
      unless input[:posting_date] == input[:through_date]
        raise InvalidControl, "posting date must equal the allocation through date"
      end
      input[:request_sha256] = Digest::SHA256.hexdigest(
        Folio::KhataHash.canonical_payload(input.except(:request_sha256).transform_values(&:to_s))
      )
      input
    end

    def sender_balance(cycle, start_date, through_date)
      JournalEntryLineAmount.joins(entry_line: :entry)
        .joins("JOIN ledgers allocation_ledgers ON allocation_ledgers.id = entry_lines.ledger_id " \
          "AND allocation_ledgers.tenant_id = entry_lines.tenant_id")
        .where(
          entry_lines: {
            tenant_id: cycle.tenant_id, cost_object_type: "cost_center",
            entity_id: cycle.entity_id, office_id: cycle.office_id,
            cost_object_id: cycle.sender_cost_center_id, account_code: cycle.source_account_code,
            line_class: "real", posting_layer: "00"
          },
          entries: { posting_date: start_date..through_date },
          slot_role: "transaction", currency: cycle.entity.functional_currency
        ).where("allocation_ledgers.posts_to_gl = TRUE")
        .sum(:amount_minor).then { |amount| [ Integer(amount), 0 ].max }
    end

    def allocate_exactly(total, receivers)
      return receivers.index_with { 0 } if total.zero?

      rows = receivers.map do |receiver|
        numerator = total * receiver.weight_basis_points
        [ receiver, numerator.div(10_000), numerator % 10_000 ]
      end
      remainder = total - rows.sum { |(_, base, _)| base }
      rows.sort_by { |receiver, _, fraction| [ -fraction, receiver.cost_center_id ] }
        .first(remainder).each { |row| row[1] += 1 }
      rows.to_h { |receiver, amount, _| [ receiver, amount ] }
    end

    def post!(cycle, actor, input, allocations)
      ledger = Ledger.find_by!(tenant_id: cycle.tenant_id, code: "PRIMARY")
      amount = lambda do |minor|
        [ {
          slot_role: "transaction", currency: cycle.entity.functional_currency,
          minor_unit_exponent: CurrencyProfile.exponent_for!(cycle.entity.functional_currency),
          amount_minor: minor
        } ]
      end
      lines = allocations.filter_map.with_index(1) do |(receiver, receiver_amount), index|
        next unless receiver_amount.positive?

        Dimensions.line_fields(receiver.cost_center, on: input.fetch(:posting_date)).merge(
          line_no: index, account_code: cycle.source_account_code, ledger_id: ledger.id,
          entity_id: cycle.entity_id, office_id: cycle.office_id,
          amounts: amount.call(receiver_amount),
          extra: Dimensions.line_fields(receiver.cost_center, on: input.fetch(:posting_date))
            .fetch(:extra).merge("allocationCycleCode" => cycle.code)
        )
      end
      sender = Dimensions.line_fields(cycle.sender_cost_center, on: input.fetch(:posting_date))
      lines << sender.merge(
        line_no: lines.size + 1, account_code: cycle.source_account_code, ledger_id: ledger.id,
        entity_id: cycle.entity_id, office_id: cycle.office_id,
        amounts: amount.call(-allocations.values.sum),
        extra: sender.fetch(:extra).merge("allocationCycleCode" => cycle.code)
      )
      entry = Posting::PostEntry.post!(
        tenant_id: cycle.tenant_id, entity_id: cycle.entity_id, office_id: cycle.office_id,
        actor: "u:#{actor.id}", actor_user_id: actor.id, origin: "folio.controlling.allocation",
        document_date: input.fetch(:posting_date), posting_date: input.fetch(:posting_date),
        entered_at: Time.current,
        fiscal_year: Documents.fiscal_year(
          input.fetch(:posting_date), variant: cycle.entity.fiscal_year_variant
        ),
        period_no: Documents.period_no(
          input.fetch(:posting_date), variant: cycle.entity.fiscal_year_variant
        ),
        authority: Authorization.authority_for(
          user: actor, tenant_id: cycle.tenant_id, office_id: cycle.office_id
        ), capabilities: capabilities_for(cycle, actor), lines: lines
      )
      LedgerEvent.find(entry.ledger_event_id)
    end

    def result(cycle, allocations)
      {
        "cycleCode" => cycle.code,
        "sourceAccountCode" => cycle.source_account_code,
        "allocatedAmountMinor" => allocations.values.sum,
        "receivers" => allocations.map do |receiver, amount|
          {
            "costCenterId" => receiver.cost_center_id,
            "costCenterCode" => receiver.cost_center.code,
            "weightBasisPoints" => receiver.weight_basis_points,
            "amountMinor" => amount
          }
        end
      }
    end

    def assert_same!(existing, input)
      return existing if existing.request_sha256 == input.fetch(:request_sha256)

      raise InvalidControl, "the idempotency key already belongs to another allocation run"
    end

    def authorize!(cycle, actor)
      return if Authorization.permits?(
        user: actor, tenant_id: cycle.tenant_id, office_id: cycle.office_id,
        capability: "controlling.allocate"
      )

      raise InvalidControl, "not permitted to run controlling allocations"
    end

    def capabilities_for(cycle, actor)
      Authorization.role_for(user: actor, tenant_id: cycle.tenant_id, office_id: cycle.office_id)
        &.role_template&.role_permissions&.pluck(:capability) || []
    end

    def parse_date(raw, label)
      return raw if raw.is_a?(Date)

      Date.iso8601(raw.to_s)
    rescue Date::Error
      raise InvalidControl, "#{label} must be a valid ISO date"
    end

    def value(attributes, key)
      attributes[key] || attributes[key.to_s]
    end
  end
end
