# frozen_string_literal: true

module Contracts
  module Create
    ATTRIBUTES = %i[
      title contract_type effective_date end_date enforceable_period_end term_type auto_renew
      renewal_notice_days currency total_contract_value_minor jurisdiction instrument_type
      execution_date stamp_status stamp_state_code stamp_amount_minor stamp_certificate_reference
      stamp_date signature_status registration_required registration_status registration_reference
      tds_section gst_treatment place_of_supply_state_code hsn_sac_code
    ].freeze

    module_function

    def call(tenant:, party_id:, attributes:, actor:)
      values = attributes.to_h.symbolize_keys.slice(*ATTRIBUTES)
      Contract.transaction do
        entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
        office = Office.find_by!(tenant_id: tenant.id, entity_id: entity.id, code: "PRIMARY")
        party = Party.active.where(tenant_id: tenant.id).find(party_id)
        start_date = parse_date(values[:effective_date]) || tenant.business_date
        fiscal_year = Contracts.fiscal_year(start_date, variant: entity.fiscal_year_variant)
        sequence = ContractNumberRange.allocate!(
          tenant_id: tenant.id, entity_id: entity.id, office_id: office.id, fiscal_year: fiscal_year
        )
        number = Contracts.format_number(fiscal_year, sequence)
        event = DomainEvents::Record.call(
          tenant_id: tenant.id,
          office_id: office.id,
          kind: "contract.drafted",
          actor: "u:#{actor.id}",
          actor_user_id: actor.id,
          ref: number,
          payload: {
            "contractNumber" => number,
            "title" => values[:title],
            "side" => "sell",
            "partyId" => party.id,
            "status" => "draft"
          }
        )
        Contract.create!(
          values.merge(
            tenant_id: tenant.id, entity: entity, office: office, party: party,
            contract_number: number, fiscal_year: fiscal_year, side: "sell",
            accounting_treatment: "revenue_115", created_domain_event: event
          )
        )
      end
    end

    def parse_date(value)
      return value if value.is_a?(Date)
      return if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      raise Contracts::InvalidContract, "effective date must be a valid ISO date"
    end
  end
end
