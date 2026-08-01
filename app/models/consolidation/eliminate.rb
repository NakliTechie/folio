# frozen_string_literal: true

module Consolidation
  module Eliminate
    module_function

    def call(transaction:, actor:, attributes:)
      group = transaction.consolidation_group
      authorize!(group, actor)
      date = parse_date(attributes[:posting_date] || attributes["posting_date"])
      key = (attributes[:idempotency_key] || attributes["idempotency_key"]).to_s.strip
      raise InvalidConsolidation, "idempotency key is required" if key.blank?
      request_sha256 = Digest::SHA256.hexdigest(Folio::KhataHash.canonical_payload(
        "intercompanyTransactionId" => transaction.id, "postingDate" => date.to_s
      ))

      ConsolidationEliminationRun.transaction do
        LedgerEvent.acquire_tenant_lock!(transaction.tenant_id)
        existing = ConsolidationEliminationRun.find_by(
          tenant_id: transaction.tenant_id, intercompany_transaction_id: transaction.id
        ) || ConsolidationEliminationRun.find_by(tenant_id: transaction.tenant_id, idempotency_key: key)
        return assert_same!(existing, transaction, request_sha256) if existing

        source = Entry.find_by!(ledger_event_id: transaction.ledger_event_id)
        lines = source.entry_lines.includes(:amounts).order(:line_no).map.with_index(1) do |line, number|
          {
            line_no: number, account_code: line.account_code, ledger_id: line.ledger_id,
            entity_id: line.entity_id, office_id: line.office_id,
            posting_layer: "EL", partner_entity_id: line.partner_entity_id,
            intercompany_transaction_id: transaction.transaction_code,
            extra: {
              "eliminatesLedgerEventId" => transaction.ledger_event_id,
              "intercompanyTransactionCode" => transaction.transaction_code
            },
            amounts: line.amounts.map do |amount|
              {
                slot_role: amount.slot_role, currency: amount.currency,
                minor_unit_exponent: amount.minor_unit_exponent,
                amount_minor: -amount.amount_minor, rate: amount.rate,
                rate_date: amount.rate_date, rate_source: amount.rate_source,
                rate_basis: amount.rate_basis
              }.compact
            end
          }
        end
        entity = transaction.seller_entity
        entry = Posting::PostEntry.post!(
          tenant_id: transaction.tenant_id, actor: "u:#{actor.id}", actor_user_id: actor.id,
          origin: "folio.consolidation.elimination", document_date: date, posting_date: date,
          entered_at: Time.current,
          fiscal_year: Documents.fiscal_year(date, variant: entity.fiscal_year_variant),
          period_no: Documents.period_no(date, variant: entity.fiscal_year_variant),
          authority: Authorization.authority_for(user: actor, tenant_id: transaction.tenant_id),
          capabilities: Authorization.role_for(user: actor, tenant_id: transaction.tenant_id)
            .role_template.role_permissions.pluck(:capability),
          lines: lines
        )
        ConsolidationEliminationRun.create!(
          tenant_id: transaction.tenant_id, consolidation_group: group,
          intercompany_transaction: transaction, created_by: actor,
          ledger_event_id: entry.ledger_event_id, idempotency_key: key,
          request_sha256: request_sha256, posting_date: date
        )
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def assert_same!(existing, transaction, request_sha256)
      return existing if existing.intercompany_transaction_id == transaction.id &&
        existing.request_sha256 == request_sha256
      raise InvalidConsolidation, "elimination idempotency evidence belongs to another request"
    end

    def authorize!(group, actor)
      return if Authorization.permits?(
        user: actor, tenant_id: group.tenant_id, capability: "consolidation.post"
      )
      raise InvalidConsolidation, "not permitted to post eliminations"
    end

    def parse_date(value)
      return value if value.is_a?(Date)
      Date.iso8601(value.to_s)
    rescue Date::Error
      raise InvalidConsolidation, "elimination date must be a valid ISO date"
    end
  end
end
