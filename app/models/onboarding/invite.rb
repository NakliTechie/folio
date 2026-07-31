# frozen_string_literal: true

module Onboarding
  # The invite path: an owner creates an Invitation; the invitee accepts via its signed token to
  # get a User (if new) + Membership + the assigned role. Single-use (accepted_at).
  module Invite
    AlreadyAccepted = Class.new(StandardError)
    AlreadyMember = Class.new(StandardError)
    AuthenticationRequired = Class.new(StandardError)
    Acceptance = Data.define(:user, :tenant)

    module_function

    def create!(tenant:, email:, role_code:, invited_by:)
      Invitation.create!(tenant: tenant, email: email, role_code: role_code, invited_by: invited_by)
    end

    # Backwards-compatible service entry point for internal callers that only need the user.
    def accept!(token:, password: nil, authenticated_user: nil)
      accept_with_context!(token: token, password: password, authenticated_user: authenticated_user)&.user
    end

    # Returns both the user and the company accepted so HTTP callers never have to resolve the
    # signed token a second time or guess which company should become current.
    def accept_with_context!(token:, password: nil, authenticated_user: nil)
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

        raise AlreadyMember, "You already belong to this company; ask an owner to change your role." if
          Membership.exists?(user: user, tenant: inv.tenant)

        Membership.create!(user: user, tenant: inv.tenant)
        Rbac::Presets.seed_for!(inv.tenant)
        role = Rbac::Presets.role_for(inv.tenant, inv.role_code)
        UserOfficeRole.create!(user: user, tenant_id: inv.tenant_id, office_id: nil, role_template: role)
        inv.update!(accepted_at: Time.current)
        Acceptance.new(user: user, tenant: inv.tenant)
      end
    end
  end
end
