# frozen_string_literal: true

module Parties
  module Manage
    AUDITED_FIELDS = %w[
      party_number name active email phone address_line1 address_line2 city postal_code state_code country_code
    ].freeze

    module_function

    def create!(tenant:, attributes:, roles:, actor:, tax_registration_attributes: nil)
      Party.transaction do
        party = Party.create!(attributes.merge(tenant_id: tenant.id))
        replace_roles!(party, roles)
        registration = sync_tax_registration!(party, tax_registration_attributes)
        changes = party.attributes.slice(*AUDITED_FIELDS).transform_values { |value| { "to" => value } }
        changes["tax_registration"] = { "to" => registration_summary(registration) } if registration
        append_event!(party, "party.created", actor, changes)
        party
      end
    end

    def update!(party:, attributes:, roles:, actor:, tax_registration_attributes: nil)
      Party.transaction do
        party.lock!
        before_roles = party.role_codes
        before_registration = registration_summary(party.party_tax_registrations.order(valid_from: :desc).first)
        party.assign_attributes(attributes)
        changes = party.changes.slice(*AUDITED_FIELDS).transform_values do |before, after|
          { "from" => before, "to" => after }
        end
        replace_roles!(party, roles)
        after_roles = party.role_codes
        changes["roles"] = { "from" => before_roles, "to" => after_roles } unless before_roles == after_roles
        registration = sync_tax_registration!(party, tax_registration_attributes)
        after_registration = registration_summary(registration)
        unless before_registration == after_registration
          changes["tax_registration"] = { "from" => before_registration, "to" => after_registration }
        end
        return party if changes.empty?

        party.save!
        action = MasterData::Audit.lifecycle_action("party", changes)
        append_event!(party, action, actor, changes)
        party
      end
    end

    def sync_tax_registration!(party, attributes)
      return party.party_tax_registrations.order(valid_from: :desc).first unless attributes

      values = attributes.to_h.symbolize_keys
      identifier = values[:identifier].to_s.strip
      registrations = party.party_tax_registrations.where(kind: values[:kind].presence || "GSTIN")
      current = registrations.order(valid_from: :desc, id: :desc).first
      if identifier.blank?
        registrations.active.update_all(active: false, updated_at: Time.current)
        return current
      end

      valid_from = values[:valid_from].presence
      registration = registrations.find_or_initialize_by(
        tenant_id: party.tenant_id,
        identifier: identifier,
        valid_from: valid_from
      )
      registration.assign_attributes(values.slice(:kind, :identifier, :valid_from, :valid_to, :active))
      registration.active = true

      if registration.valid_from.present?
        other_active = registrations.active.where.not(id: registration.id)
        other_active.where(valid_from: registration.valid_from).update_all(active: false, updated_at: Time.current)

        other_active.where("valid_from < ?", registration.valid_from)
          .where("valid_to IS NULL OR valid_to >= ?", registration.valid_from)
          .find_each do |prior|
            prior.update!(valid_to: registration.valid_from - 1.day)
          end

        next_start = other_active.where("valid_from > ?", registration.valid_from).minimum(:valid_from)
        if next_start && (registration.valid_to.nil? || registration.valid_to >= next_start)
          registration.valid_to = next_start - 1.day
        end
      end

      registration.save!
      if party.country_code == "IN" && party.state_code.present? && party.state_code != registration.state_code
        party.errors.add(:state_code, "must match the GSTIN state code #{registration.state_code}")
        raise ActiveRecord::RecordInvalid.new(party)
      end
      registration
    end

    def registration_summary(registration)
      return unless registration

      {
        "id" => registration.id, "kind" => registration.kind,
        "identifier" => registration.identifier, "stateCode" => registration.state_code,
        "validFrom" => registration.valid_from&.iso8601,
        "validTo" => registration.valid_to&.iso8601, "active" => registration.active
      }
    end

    def replace_roles!(party, roles)
      normalized = Array(roles).map(&:to_s).select(&:present?).uniq
      if normalized.empty?
        party.errors.add(:party_roles, "must include at least one role")
        raise ActiveRecord::RecordInvalid.new(party)
      end
      invalid = normalized - PartyRole::ROLES
      if invalid.any?
        party.errors.add(:party_roles, "include unsupported roles: #{invalid.join(", ")}")
        raise ActiveRecord::RecordInvalid.new(party)
      end

      removed = party.role_codes - normalized
      if removed.any? && EntryLine.where(tenant_id: party.tenant_id, party_id: party.id, party_role: removed).exists?
        party.errors.add(:party_roles, "cannot remove a role used by posted entries")
        raise ActiveRecord::RecordInvalid.new(party)
      end

      party.party_roles.where.not(role: normalized).delete_all
      normalized.each { |role| party.party_roles.find_or_create_by!(role: role) }
    end

    def append_event!(party, action, actor, changes)
      MasterData::Audit.append!(
        tenant_id: party.tenant_id, actor: actor, action: action, ref: party.party_number,
        subject: {
          "id" => party.id, "partyNumber" => party.party_number, "name" => party.name,
          "roles" => party.role_codes, "active" => party.active
        },
        changes: changes
      )
    end
  end
end
