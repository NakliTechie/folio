# frozen_string_literal: true

module Contracts
  module Milestones
    module_function

    ATTRIBUTES = %i[
      description planned_date recognition_amount_minor triggers_billing
      triggers_recognition acceptance_required
    ].freeze

    def create!(obligation:, attributes:, actor:)
      ContractMilestone.transaction do
        contract = obligation.contract.lock!
        raise InvalidContract, "milestones can only be added to a draft contract" unless contract.status == "draft"
        raise InvalidContract, "milestones belong to point-in-time obligations" unless obligation.satisfaction == "point_in_time"

        milestone = obligation.contract_milestones.create!(
          attributes.to_h.symbolize_keys.slice(*ATTRIBUTES).merge(
            tenant_id: contract.tenant_id, contract: contract,
            milestone_no: obligation.contract_milestones.maximum(:milestone_no).to_i + 1
          )
        )
        DomainEvents::Record.call(
          tenant_id: contract.tenant_id, office_id: contract.office_id,
          kind: "contract.milestone_added", actor: "u:#{actor.id}",
          actor_user_id: actor.id, ref: contract.contract_number,
          payload: {
            "contractNumber" => contract.contract_number,
            "obligationNo" => obligation.obligation_no,
            "milestoneNo" => milestone.milestone_no,
            "plannedDate" => milestone.planned_date.iso8601,
            "recognitionAmountMinor" => milestone.recognition_amount_minor
          }
        )
        milestone
      end
    end

    def achieve!(milestone:, actor:, achieved_date:, acceptance_date: nil)
      ContractMilestone.transaction do
        milestone.lock!
        raise InvalidContract, "only a planned milestone can be achieved" unless milestone.status == "planned"

        milestone.update!(
          status: "achieved", achieved_date: achieved_date,
          acceptance_date: acceptance_date
        )
        contract = milestone.contract
        DomainEvents::Record.call(
          tenant_id: contract.tenant_id, office_id: contract.office_id,
          kind: "contract.milestone_achieved", actor: "u:#{actor.id}",
          actor_user_id: actor.id, ref: contract.contract_number,
          payload: {
            "contractNumber" => contract.contract_number,
            "obligationNo" => milestone.contract_performance_obligation.obligation_no,
            "milestoneNo" => milestone.milestone_no,
            "achievedDate" => milestone.achieved_date.iso8601,
            "acceptanceDate" => milestone.acceptance_date&.iso8601
          }.compact
        )
        milestone
      end
    end
  end
end
