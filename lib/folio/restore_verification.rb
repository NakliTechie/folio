# frozen_string_literal: true

module Folio
  module RestoreVerification
    module_function

    def call
      tenants = Tenant.order(:id).to_a
      raise "restored primary database contains no tenants" if tenants.empty?

      results = tenants.map do |tenant|
        ledger = LedgerEvent.verify_chain(tenant.id)
        domain = DomainEvent.verify_chain(tenant.id)
        raise "tenant #{tenant.id} ledger event chain is invalid" unless ledger.fetch(:ok)
        raise "tenant #{tenant.id} domain event chain is invalid" unless domain.fetch(:ok)

        entities = Entity.where(tenant_id: tenant.id).order(:id).map do |entity|
          trial_balance = Reports.trial_balance(tenant.id, entity_id: entity.id)
          debit = trial_balance.sum { |row| row.fetch("debit") }
          credit = trial_balance.sum { |row| row.fetch("credit") }
          raise "tenant #{tenant.id} entity #{entity.id} trial balance is unbalanced" unless debit == credit

          { entity_id: entity.id, debit_minor: debit, credit_minor: credit }
        end
        {
          tenant_id: tenant.id, ledger_rows: ledger.fetch(:rows),
          domain_rows: domain.fetch(:rows), entities: entities
        }
      end
      { status: "ok", tenant_count: tenants.size, tenants: results }
    end
  end
end
