# frozen_string_literal: true

module Procurement
  module ManageVendor
    module_function

    def onboard!(tenant:, actor:, attributes:)
      values = attributes.to_h.symbolize_keys
      party = Party.active.joins(:party_roles).where(
        tenant_id: tenant.id, party_roles: { role: "vendor" }
      ).find(values.fetch(:party_id))
      VendorProfile.transaction do
        profile = VendorProfile.create!(
          tenant_id: tenant.id, party: party, created_by: actor, status: "pending",
          spend_authorized: false,
          payment_terms_days: values[:payment_terms_days].presence || 30,
          preferred_currency: values[:preferred_currency].presence || tenant.functional_currency
        )
        DomainEvents::Record.call(
          tenant_id: tenant.id, kind: "vendor.onboarded", actor: "u:#{actor.id}",
          actor_user_id: actor.id, ref: party.party_number,
          payload: snapshot(profile)
        )
        profile
      end
    end

    def approve!(profile:, actor:)
      VendorProfile.transaction do
        profile.lock!
        raise InvalidProcurement, "only a pending vendor can be approved" unless profile.status == "pending"
        raise InvalidProcurement, "vendor creator cannot approve their own onboarding" if profile.created_by_id == actor.id
        authorize!(profile, actor, "procurement.approve")

        profile.update!(
          status: "approved", spend_authorized: true, approved_by: actor, approved_at: Time.current
        )
        DomainEvents::Record.call(
          tenant_id: profile.tenant_id, kind: "vendor.approved", actor: "u:#{actor.id}",
          actor_user_id: actor.id, ref: profile.party.party_number,
          payload: snapshot(profile)
        )
        profile
      end
    end

    def suspend!(profile:, actor:, reason:)
      explanation = reason.to_s.strip
      raise InvalidProcurement, "suspension reason is required" if explanation.blank?
      authorize!(profile, actor, "procurement.approve")

      VendorProfile.transaction do
        profile.lock!
        profile.update!(status: "suspended", spend_authorized: false,
          purchasing_hold: true, posting_hold: true, payment_hold: true)
        DomainEvents::Record.call(
          tenant_id: profile.tenant_id, kind: "vendor.suspended", actor: "u:#{actor.id}",
          actor_user_id: actor.id, ref: profile.party.party_number,
          payload: snapshot(profile).merge("reason" => explanation)
        )
        profile
      end
    end

    def snapshot(profile)
      {
        "vendorProfileId" => profile.id, "partyId" => profile.party_id,
        "partyNumber" => profile.party.party_number, "name" => profile.party.name,
        "status" => profile.status, "spendAuthorized" => profile.spend_authorized,
        "purchasingHold" => profile.purchasing_hold,
        "postingHold" => profile.posting_hold, "paymentHold" => profile.payment_hold,
        "paymentTermsDays" => profile.payment_terms_days,
        "preferredCurrency" => profile.preferred_currency,
        "approvedById" => profile.approved_by_id, "approvedAt" => profile.approved_at&.iso8601(6)
      }.compact
    end

    def authorize!(profile, actor, capability)
      return if Authorization.permits?(
        user: actor, tenant_id: profile.tenant_id, capability: capability
      )

      raise InvalidProcurement, "not permitted to approve vendor procurement status"
    end
  end
end
