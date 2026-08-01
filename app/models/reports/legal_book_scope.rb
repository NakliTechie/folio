# frozen_string_literal: true

module Reports
  # The boundary shared by every ordinary legal-book report. A report is always for one
  # legal entity, the statutory posting layer (00), and that entity's functional currency.
  # Consolidation/elimination layers have their own reporting surface and must never leak here.
  module LegalBookScope
    MissingFunctionalAmount = Class.new(StandardError)
    ProjectionEntity = Data.define(:id, :code, :legal_name, :functional_currency)
    Context = Data.define(:entity, :lines) do
      def currency
        entity.functional_currency
      end
    end

    LEDGER_JOIN = <<~SQL.squish.freeze
      JOIN ledgers legal_report_ledgers
        ON legal_report_ledgers.id = entry_lines.ledger_id
       AND legal_report_ledgers.tenant_id = entry_lines.tenant_id
       AND legal_report_ledgers.posts_to_gl = TRUE
    SQL

    module_function

    def call(tenant_id:, entity_id: nil, include_statistical: false)
      entity = resolve_entity!(tenant_id, entity_id)
      classes = include_statistical ? EntryLine::LINE_CLASSES : [ "real" ]
      base = EntryLine.where(
        tenant_id: tenant_id, entity_id: entity.id, posting_layer: "00", line_class: classes
      ).joins(LEDGER_JOIN)
      ensure_reportable!(base.where(line_class: "real"), entity)
      Context.new(entity, base.joins(amount_join(entity.functional_currency)))
    end

    def amount_for(line, entity)
      currency = entity.functional_currency
      functional = line.amounts.find do |amount|
        amount.slot_role == "functional" && amount.currency == currency
      end
      return functional.amount_minor if functional

      transaction = line.amounts.find do |amount|
        amount.slot_role == "transaction" && amount.currency == currency
      end
      return transaction.amount_minor if transaction

      raise MissingFunctionalAmount,
        "line #{line.id} has no amount in entity functional currency #{currency}"
    end

    def functional_open_amount(line, entity)
      transaction = line.amounts.find { |amount| amount.slot_role == "transaction" }
      return 0 unless transaction

      open_transaction = Posting::Clearing.open_amount(line)
      return 0 unless open_transaction.positive?

      reporting = amount_for(line, entity).abs
      return reporting if open_transaction == transaction.amount_minor.abs

      (BigDecimal(reporting.to_s) * open_transaction / transaction.amount_minor.abs)
        .round(0, BigDecimal::ROUND_HALF_EVEN).to_i
    end

    def resolve_entity!(tenant_id, entity_id = nil)
      scope = Entity.where(tenant_id: tenant_id)
      return scope.find(entity_id) if entity_id.present?

      entity = scope.find_by(code: "PRIMARY")
      return entity if entity

      # The read-only Tier-R projection harness intentionally imports without creating a
      # Tenant/Entity spine. Keep that isolated compatibility path while production tenants
      # fail closed if their legal entity is missing.
      raise ActiveRecord::RecordNotFound, "primary legal entity is missing" if Tenant.exists?(id: tenant_id)

      projection_entity(tenant_id)
    end

    def projection_entity(tenant_id)
      entity_ids = EntryLine.where(tenant_id: tenant_id).distinct.pluck(:entity_id)
      currencies = JournalEntryLineAmount.where(tenant_id: tenant_id, slot_role: "transaction")
        .distinct.pluck(:currency)
      unless entity_ids.one? && currencies.one?
        raise ActiveRecord::RecordNotFound,
          "projection-only reports require exactly one entity and one transaction currency"
      end

      ProjectionEntity.new(entity_ids.first, "PRIMARY", "Primary", currencies.first)
    end

    def ensure_reportable!(scope, entity)
      currency = ActiveRecord::Base.connection.quote(entity.functional_currency)
      missing = scope.where(<<~SQL.squish).exists?
        NOT EXISTS (
          SELECT 1
            FROM journal_entry_line_amounts legal_amount_presence
           WHERE legal_amount_presence.entry_line_id = entry_lines.id
             AND legal_amount_presence.currency = #{currency}
             AND (
               legal_amount_presence.slot_role = 'functional'
               OR legal_amount_presence.slot_role = 'transaction'
             )
        )
      SQL
      return unless missing

      raise MissingFunctionalAmount,
        "legal-book lines are missing amounts in entity functional currency #{entity.functional_currency}"
    end

    def amount_join(functional_currency)
      currency = ActiveRecord::Base.connection.quote(functional_currency)
      <<~SQL.squish
        JOIN journal_entry_line_amounts legal_report_amounts
          ON legal_report_amounts.entry_line_id = entry_lines.id
         AND legal_report_amounts.currency = #{currency}
         AND (
           legal_report_amounts.slot_role = 'functional'
           OR (
             legal_report_amounts.slot_role = 'transaction'
             AND NOT EXISTS (
               SELECT 1
                 FROM journal_entry_line_amounts functional_report_amounts
                WHERE functional_report_amounts.entry_line_id = entry_lines.id
                  AND functional_report_amounts.slot_role = 'functional'
                  AND functional_report_amounts.currency = #{currency}
             )
           )
         )
      SQL
    end
  end
end
