# frozen_string_literal: true

module Taxes
  module India
    # Freezes how a GST place of supply was selected. The party address is the safe default;
    # an explicit departure requires both a reason and an actor who held the dedicated authority.
    module PlaceOfSupplyEvidence
      OVERRIDE_CAPABILITY = "gst.place_of_supply.override"
      BASES = %w[party_address manual_override legacy_explicit].freeze
      MAX_REASON_LENGTH = 500

      module_function

      def build!(tenant:, party:, selected_state_code:, actor: nil, override_reason: nil,
                 error_class: ArgumentError)
        selected = selected_state_code.to_s
        party_state = party.state_code.to_s
        if party_state.blank?
          raise error_class, "the selected party needs a state before choosing the place of supply"
        end

        return {
          "basis" => "party_address",
          "selectedStateCode" => selected,
          "partyStateCode" => party_state
        } if selected == party_state

        reason = override_reason.to_s.strip
        if reason.blank? || reason.length > MAX_REASON_LENGTH
          raise error_class,
            "explain why the place of supply differs from the party address (maximum #{MAX_REASON_LENGTH} characters)"
        end
        unless actor && Authorization.permits?(
          user: actor, tenant_id: tenant.id, capability: OVERRIDE_CAPABILITY
        )
          raise error_class, "you are not permitted to override the party-address place of supply"
        end

        {
          "basis" => "manual_override",
          "selectedStateCode" => selected,
          "partyStateCode" => party_state,
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
          raise error_class, "party-address place-of-supply evidence was altered" unless selected == party_state
        when "manual_override"
          valid_override = selected != party_state && evidence["reason"].to_s.present? &&
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
