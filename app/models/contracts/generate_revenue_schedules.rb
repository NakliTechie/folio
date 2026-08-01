# frozen_string_literal: true

module Contracts
  module GenerateRevenueSchedules
    module_function

    def call(contract:, actor:)
      Contract.transaction do
        contract.lock!
        raise InvalidContract, "activate the contract before generating revenue schedules" unless contract.status == "active"

        allocation = contract.contract_allocation_runs.in_version_order.last
        raise InvalidContract, "allocate the transaction price before generating schedules" unless allocation
        assert_allocation_current!(contract, allocation)

        current = contract.contract_schedules.current.includes(:contract_schedule_lines).to_a
        if current.any? { |schedule| schedule.contract_schedule_lines.any?(&:posted_ledger_event_id?) }
          raise InvalidContract,
            "posted schedules cannot be regenerated; close this contract and create a replacement for changed terms"
        end

        current.each do |schedule|
          schedule.contract_schedule_lines.update_all(status: "superseded", updated_at: Time.current)
          schedule.update!(status: "superseded")
        end

        allocation.contract_allocation_lines.includes(
          contract_performance_obligation: :contract_milestones
        ).sort_by { |line| line.contract_performance_obligation.obligation_no }.map do |allocation_line|
          generate_one!(contract, allocation_line, actor)
        end
      end
    end

    def generate_one!(contract, allocation_line, actor)
      obligation = allocation_line.contract_performance_obligation
      version = obligation.contract_schedules.maximum(:version).to_i + 1
      line_specs = if obligation.over_time?
        time_elapsed_specs(contract, obligation, allocation_line.allocated_price_minor)
      else
        milestone_specs(contract, obligation, allocation_line.allocated_price_minor)
      end
      event = DomainEvents::Record.call(
        tenant_id: contract.tenant_id, office_id: contract.office_id,
        kind: "contract.revenue_schedule_generated", actor: "u:#{actor.id}",
        actor_user_id: actor.id, ref: contract.contract_number,
        payload: {
          "contractNumber" => contract.contract_number,
          "obligationNo" => obligation.obligation_no,
          "version" => version, "method" => obligation.recognition_method,
          "allocatedPriceMinor" => allocation_line.allocated_price_minor,
          "lineCount" => line_specs.size
        }
      )
      schedule = contract.contract_schedules.create!(
        tenant_id: contract.tenant_id, office: contract.office,
        contract_performance_obligation: obligation,
        contract_allocation_line: allocation_line, created_domain_event: event,
        version: version, method: obligation.recognition_method,
        currency: contract.currency, generated_at: Time.current
      )
      line_specs.each_with_index do |spec, index|
        schedule.contract_schedule_lines.create!(
          spec.merge(
            tenant_id: contract.tenant_id, sequence: index + 1,
            revenue_account_code: obligation.revenue_account_code
          )
        )
      end
      schedule
    end

    def time_elapsed_specs(contract, obligation, amount)
      start_date = obligation.service_start_date || contract.effective_date
      end_date = obligation.service_end_date || contract.end_date
      raise InvalidContract, "over-time obligations need a service start and end date" unless start_date && end_date
      raise InvalidContract, "service end cannot precede service start" if end_date < start_date

      periods = []
      cursor = start_date
      while cursor <= end_date
        period_end = [ cursor.next_month - 1.day, end_date ].min
        periods << [ cursor, period_end ]
        cursor = period_end + 1.day
      end
      amounts = allocate_by_days(amount, periods)
      periods.each_with_index.map do |(period_start, period_end), index|
        {
          period_start: period_start, period_end: period_end, due_date: period_end,
          original_effective_date: period_end, amount_minor: amounts.fetch(index)
        }
      end
    end

    def milestone_specs(contract, obligation, amount)
      milestones = obligation.contract_milestones.in_number_order.select(&:triggers_recognition?)
      if milestones.empty?
        date = obligation.service_end_date || contract.end_date || contract.effective_date
        raise InvalidContract, "point-in-time obligations need a milestone or satisfaction date" unless date
        return [ {
          period_start: date, period_end: date, due_date: date,
          original_effective_date: date, amount_minor: amount
        } ]
      end
      total = milestones.sum(&:recognition_amount_minor)
      unless total == amount
        raise InvalidContract,
          "recognition milestones total #{total} minor units; allocated price is #{amount}"
      end

      milestones.map do |milestone|
        {
          contract_milestone: milestone, period_start: milestone.planned_date,
          period_end: milestone.planned_date, due_date: milestone.planned_date,
          original_effective_date: milestone.planned_date,
          amount_minor: milestone.recognition_amount_minor
        }
      end
    end

    def allocate_by_days(amount, periods)
      total_days = periods.sum { |start_date, end_date| (end_date - start_date).to_i + 1 }
      shares = periods.each_with_index.map do |(start_date, end_date), index|
        days = (end_date - start_date).to_i + 1
        numerator = amount * days
        [ index, numerator.div(total_days), numerator % total_days ]
      end
      residual = amount - shares.sum { |(_, floor, _)| floor }
      shares.sort_by { |index, _, remainder| [ -remainder, index ] }
        .first(residual).each { |share| share[1] += 1 }
      shares.sort_by(&:first).map { |(_, allocated, _)| allocated }
    end

    def assert_allocation_current!(contract, allocation)
      obligations = contract.contract_performance_obligations.in_number_order.to_a
      lines = allocation.contract_allocation_lines.to_a
      current_ssp = obligations.sum(&:standalone_selling_price_minor)
      valid = allocation.transaction_price_minor == contract.total_contract_value_minor &&
        allocation.total_ssp_minor == current_ssp &&
        lines.map(&:contract_performance_obligation_id).sort == obligations.map(&:id).sort &&
        lines.all? do |line|
          line.standalone_selling_price_minor ==
            line.contract_performance_obligation.standalone_selling_price_minor
        end
      return if valid

      raise InvalidContract, "the allocation no longer matches the contract terms and obligations"
    end
  end
end
