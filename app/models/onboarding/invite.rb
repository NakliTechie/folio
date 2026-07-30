# frozen_string_literal: true

module Onboarding
  # The invite path: an owner creates an Invitation; the invitee accepts via its signed token to
  # get a User (if new) + Membership + the assigned role. Single-use (accepted_at).
  module Invite
    AlreadyAccepted = Class.new(StandardError)
    AuthenticationRequired = Class.new(StandardError)

    module_function

    def create!(tenant:, email:, role_code:, invited_by:)
      Invitation.create!(tenant: tenant, email: email, role_code: role_code, invited_by: invited_by)
    end

    # Returns the User, or nil if the token is invalid/expired.
    def accept!(token:, password: nil, authenticated_user: nil)
      inv = Invitation.find_by_token_for(:invite, token)
      return nil unless inv

      ActiveRecord::Base.transaction do
        inv.lock!
        raise AlreadyAccepted, "invitation already used" unless inv.pending?

        user = User.find_by(email_address: inv.email)
        if user
          authenticated = authenticated_user == user || (password.present? && user.authenticate(password))
          raise AuthenticationRequired, "confirm the password for #{inv.email}" unless authenticated
        else
          user = User.create!(email_address: inv.email, password: password)
        end

        Membership.find_or_create_by!(user: user, tenant: inv.tenant)
        Rbac::Presets.seed_for!(inv.tenant)
        role = Rbac::Presets.role_for(inv.tenant, inv.role_code)
        assignment = UserOfficeRole.find_or_initialize_by(user: user, tenant_id: inv.tenant_id, office_id: nil)
        assignment.update!(role_template: role)
        inv.update!(accepted_at: Time.current)
        user
      end
    end
  end
end
