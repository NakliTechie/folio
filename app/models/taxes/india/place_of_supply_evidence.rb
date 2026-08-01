# frozen_string_literal: true

module Taxes
  module India
    # Freezes how a GST place of supply was selected. Sales default to the customer address;
    # purchases may instead default to the buyer GST registration. A departure from the applicable
    # transaction-side default requires a reason and an actor who held the dedicated authority.
    module PlaceOfSupplyEvidence
      OVERRIDE_CAPABILITY = "gst.place_of_supply.override"
      DEFAULT_BASES = %w[party_address buyer_registration].freeze
      BASES = [ *DEFAULT_BASES, "manual_override", "legacy_explicit" ].freeze
      MAX_REASON_LENGTH = 500

      module_function

      def build!(tenant:, party:, selected_state_code:, actor: nil, override_reason: nil,
                 default_basis: "party_address", default_state_code: nil,
                 error_class: ArgumentError)
        selected = selected_state_code.to_s
        party_state = party.state_code.to_s
        if party_state.blank?
          raise error_class, "the selected party needs a state before choosing the place of supply"
        end
        unless DEFAULT_BASES.include?(default_basis)
          raise error_class, "place-of-supply default basis is not supported"
        end

        default_state = default_state_code.to_s.presence || party_state
        unless Taxes::India::StateCodes.valid?(default_state)
          raise error_class, "place-of-supply default must be a valid GST state code"
        end
        if default_basis == "party_address" && default_state != party_state
          raise error_class, "party-address place-of-supply default does not match the party"
        end

        return {
          "basis" => default_basis,
          "selectedStateCode" => selected,
          "partyStateCode" => party_state,
          "defaultStateCode" => default_state
        } if selected == default_state

        reason = override_reason.to_s.strip
        default_label = default_basis == "buyer_registration" ? "buyer GST registration" : "party address"
        if reason.blank? || reason.length > MAX_REASON_LENGTH
          raise error_class,
            "explain why the place of supply differs from the #{default_label} (maximum #{MAX_REASON_LENGTH} characters)"
        end
        unless actor && Authorization.permits?(
          user: actor, tenant_id: tenant.id, capability: OVERRIDE_CAPABILITY
        )
          raise error_class, "you are not permitted to override the default place of supply"
        end

        {
          "basis" => "manual_override",
          "selectedStateCode" => selected,
          "partyStateCode" => party_state,
          "defaultBasis" => default_basis,
          "defaultStateCode" => default_state,
          "reason" => reason,
          "actorId" => actor.id,
          "capability" => OVERRIDE_CAPABILITY
        }
      end

      def validate!(document, error_class: Documents::InvalidDocument)
        evidence = document.place_of_supply_evidence.to_h
        selected = document.place_of_supply_state_code.to_s
        party_state = document.party_snapshot.to_h["stateCode"].to_s
        basis = evidence["basis"]

        unless BASES.include?(basis) &&
               evidence["selectedStateCode"] == selected &&
               evidence["partyStateCode"] == party_state
          raise error_class, "place-of-supply evidence is missing or does not match the frozen document"
        end

        case basis
        when "party_address"
          default_state = evidence["defaultStateCode"].presence || party_state
          unless selected == party_state && default_state == party_state
            raise error_class, "party-address place-of-supply evidence was altered"
          end
        when "buyer_registration"
          buyer_state = document.tax_registration_snapshot.to_h["stateCode"].to_s
          unless selected == buyer_state && evidence["defaultStateCode"] == buyer_state
            raise error_class, "buyer-registration place-of-supply evidence was altered"
          end
        when "manual_override"
          default_basis = evidence["defaultBasis"].presence || "party_address"
          default_state = if default_basis == "buyer_registration"
            document.tax_registration_snapshot.to_h["stateCode"].to_s
          else
            party_state
          end
          recorded_default = evidence["defaultStateCode"].to_s.presence
          valid_default = DEFAULT_BASES.include?(default_basis) &&
            (recorded_default.nil? || recorded_default == default_state)
          valid_override = valid_default && selected != default_state && evidence["reason"].to_s.present? &&
            evidence["reason"].length <= MAX_REASON_LENGTH && evidence["actorId"].to_i.positive? &&
            evidence["capability"] == OVERRIDE_CAPABILITY
          raise error_class, "manual place-of-supply evidence is incomplete" unless valid_override
        when "legacy_explicit"
          raise error_class, "legacy place-of-supply evidence is incomplete" if evidence["reason"].to_s.blank?
        end

        true
      end
    end
  end
end
