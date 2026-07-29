# frozen_string_literal: true

module Onboarding
  # The invite path: an owner creates an Invitation; the invitee accepts via its signed token to
  # get a User (if new) + Membership + the assigned role. Single-use (accepted_at).
  module Invite
    AlreadyAccepted = Class.new(StandardError)

    module_function

    def create!(tenant:, email:, role_code:, invited_by:)
      Invitation.create!(tenant: tenant, email: email, role_code: role_code, invited_by: invited_by)
    end

    # Returns the User, or nil if the token is invalid/expired.
    def accept!(token:, password: nil)
      inv = Invitation.find_by_token_for(:invite, token)
      return nil unless inv
      raise AlreadyAccepted, "invitation already used" unless inv.pending?

      ActiveRecord::Base.transaction do
        user = User.find_or_create_by!(email_address: inv.email) { |u| u.password = password }
        Membership.find_or_create_by!(user: user, tenant: inv.tenant)
        Rbac::Presets.seed_for!(inv.tenant)
        role = Rbac::Presets.role_for(inv.tenant, inv.role_code)
        UserOfficeRole.find_or_create_by!(user: user, tenant_id: inv.tenant_id, office_id: nil) do |r|
          r.role_template = role
        end
        inv.update!(accepted_at: Time.current)
        user
      end
    end
  end
end
