# frozen_string_literal: true

require "securerandom"

module OpenItemCredits
  module Net
    Result = Data.define(:reference, :amount_minor, :credit_event, :target_event)

    module_function

    def call(tenant:, credit_entry_line_id:, target_entry_line_id:, amount_minor:, applied_on:, actor:,
             actor_user: nil)
      ActiveRecord::Base.transaction do
        LedgerEvent.acquire_tenant_lock!(tenant.id)
        lines = EntryLine.where(tenant_id: tenant.id, id: [ credit_entry_line_id, target_entry_line_id ])
          .includes(:amounts, :party).order(:id).lock.to_a
        credit = lines.find { |line| line.id.to_s == credit_entry_line_id.to_s }
        target = lines.find { |line| line.id.to_s == target_entry_line_id.to_s }
        validate_pair!(credit, target, amount_minor, applied_on)
        begin
          Settlements::PeriodGuard.assert_mutable!(lines: [ credit, target ], user: actor_user)
        rescue Settlements::InvalidReset => e
          raise InvalidCreditAction, e.message
        end

        reference = SecureRandom.uuid
        amount = Integer(amount_minor)
        metadata = { "kind" => "open_item_netting", "id" => reference }
        credit_event = Posting::Clearing.clear!(
          item: credit, amount_minor: amount, cleared_on: applied_on,
          mode: amount == Posting::Clearing.open_amount(credit) ? :full : :partial,
          actor: actor, reason: "netted against #{target.assignment}", reference: metadata
        )
        target_event = Posting::Clearing.clear!(
          item: target, amount_minor: amount, cleared_on: applied_on,
          mode: amount == Posting::Clearing.open_amount(target) ? :full : :partial,
          actor: actor, reason: "netted against credit #{credit.assignment}", reference: metadata
        )
        Result.new(reference: reference, amount_minor: amount,
          credit_event: credit_event, target_event: target_event)
      end
    rescue ActiveRecord::RecordNotFound
      raise InvalidCreditAction, "credit or target open item is unavailable"
    end

    def validate_pair!(credit, target, amount_minor, applied_on)
      unless OpenItemCredits.credit?(credit) && OpenItemCredits.target?(target) &&
             credit.party_role == target.party_role && credit.party_id == target.party_id &&
             credit.account_code == target.account_code && credit.id != target.id
        raise InvalidCreditAction, "choose an opposite open credit and charge for the same counterparty"
      end
      amount = Integer(amount_minor)
      maximum = [ Posting::Clearing.open_amount(credit), Posting::Clearing.open_amount(target) ].min
      unless amount.positive? && amount <= maximum
        raise InvalidCreditAction, "net amount must be positive and no more than the smaller open balance"
      end
      source_dates = [ credit.entry.posting_date, target.entry.posting_date ].compact
      if source_dates.any? { |date| applied_on < date }
        raise InvalidCreditAction, "netting date cannot precede either open item"
      end
    rescue ArgumentError, TypeError
      raise InvalidCreditAction, "net amount is invalid"
    end
  end
end
