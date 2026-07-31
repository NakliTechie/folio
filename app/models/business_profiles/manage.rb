# frozen_string_literal: true

module BusinessProfiles
  module Manage
    ENTITY_FIELDS = %w[legal_name].freeze
    OFFICE_FIELDS = %w[name address_line1 address_line2 city postal_code state_code country_code].freeze

    module_function

    def update!(entity:, office:, entity_attributes:, office_attributes:, actor:)
      unless entity.tenant_id == office.tenant_id && office.entity_id == entity.id
        raise InvalidProfile, "business entity and office must belong to the same company"
      end

      Entity.transaction do
        entity.lock!
        office.lock!
        entity.assign_attributes(entity_attributes.to_h.stringify_keys.slice(*ENTITY_FIELDS))
        office.assign_attributes(office_attributes.to_h.stringify_keys.slice(*OFFICE_FIELDS))
        validate_complete_address!(office)

        changes = {
          "entity" => changes_for(entity, ENTITY_FIELDS),
          "office" => changes_for(office, OFFICE_FIELDS)
        }.reject { |_section, section_changes| section_changes.empty? }
        return [ entity, office ] if changes.empty?

        entity.save!
        office.save!
        MasterData::Audit.append!(
          tenant_id: entity.tenant_id,
          actor: actor,
          action: "business_profile.updated",
          ref: entity.code,
          subject: {
            "entityId" => entity.id, "entityCode" => entity.code,
            "officeId" => office.id, "officeCode" => office.code
          },
          changes: changes
        )
        [ entity, office ]
      end
    end

    def validate_complete_address!(office)
      return if office.statutory_address_complete?

      office.errors.add(:base, "complete legal address is required for statutory documents")
      raise ActiveRecord::RecordInvalid.new(office)
    end

    def changes_for(record, fields)
      record.changes.slice(*fields).transform_values { |before, after| { "from" => before, "to" => after } }
    end
  end
end
