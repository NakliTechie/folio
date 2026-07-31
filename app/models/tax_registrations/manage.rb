# frozen_string_literal: true

module TaxRegistrations
  module Manage
    AUDITED_FIELDS = %w[kind identifier jurisdiction state_code valid_from valid_to active].freeze

    module_function

    def create!(tenant:, entity:, attributes:, office_ids:, actor:)
      TaxRegistration.transaction do
        registration = TaxRegistration.create!(attributes.merge(tenant_id: tenant.id, entity: entity))
        replace_offices!(registration, office_ids)
        append_event!(registration, "tax_registration.created", actor,
          registration.attributes.slice(*AUDITED_FIELDS).transform_values { |value| { "to" => value } })
        registration
      end
    end

    def update!(registration:, attributes:, office_ids:, actor:)
      TaxRegistration.transaction do
        registration.lock!
        before_offices = registration.office_ids.sort
        registration.assign_attributes(attributes)
        changes = registration.changes.slice(*AUDITED_FIELDS).transform_values do |before, after|
          { "from" => before, "to" => after }
        end
        replace_offices!(registration, office_ids)
        after_offices = registration.office_ids.sort
        changes["office_ids"] = { "from" => before_offices, "to" => after_offices } unless
          before_offices == after_offices
        return registration if changes.empty?

        registration.save!
        action = MasterData::Audit.lifecycle_action("tax_registration", changes)
        append_event!(registration, action, actor, changes)
        registration
      end
    end

    def replace_offices!(registration, office_ids)
      offices = Office.where(
        tenant_id: registration.tenant_id, entity_id: registration.entity_id, id: Array(office_ids)
      ).to_a
      if offices.empty?
        registration.errors.add(:offices, "must include at least one office")
        raise ActiveRecord::RecordInvalid.new(registration)
      end

      registration.office_tax_registrations.where.not(office_id: offices.map(&:id)).delete_all
      offices.each do |office|
        registration.office_tax_registrations.find_or_create_by!(
          tenant_id: registration.tenant_id, office: office
        )
      end
    end

    def append_event!(registration, action, actor, changes)
      MasterData::Audit.append!(
        tenant_id: registration.tenant_id, actor: actor, action: action,
        ref: registration.identifier,
        subject: {
          "id" => registration.id, "kind" => registration.kind,
          "identifier" => registration.identifier, "stateCode" => registration.state_code,
          "officeIds" => registration.office_ids.sort, "active" => registration.active
        },
        changes: changes
      )
    end
  end
end
