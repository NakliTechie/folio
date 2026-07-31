# frozen_string_literal: true

# The invite path. An owner (users.manage) invites an email into the current tenant with a
# role; the invitee accepts via the signed token. Accept is unauthenticated (they may have no
# account yet) and needs no current tenant.
class InvitationsController < ApplicationController
  include TenantScoped
  allow_unauthenticated_access only: %i[accept do_accept]
  skip_before_action :require_tenant, only: %i[accept do_accept]

  def create
    return head :forbidden unless owner?
    inv = Onboarding::Invite.create!(tenant: Current.tenant, email: params[:email],
                                     role_code: params[:role_code], invited_by: Current.session.user)
    inv.queue_delivery!
    redirect_to team_path(tenant_id: Current.tenant.id), notice: "Invitation queued for #{inv.email}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to team_path(tenant_id: Current.tenant.id), alert: e.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordNotUnique
    redirect_to team_path(tenant_id: Current.tenant.id),
      alert: "That email already has a pending invitation."
  end

  def accept
    @invitation = Invitation.find_by_token_for(:invite, params[:token])
    return redirect_to(new_session_path, alert: "That invitation is invalid or has expired.") unless @invitation&.pending?

    authenticated?
    if Current.user && Current.user.email_address != @invitation.email
      return redirect_to(root_path, alert: "This invitation is for #{@invitation.email}. Sign out to accept it.")
    end

    @existing_account = User.exists?(email_address: @invitation.email)
    @token = params[:token]
  end

  def do_accept
    authenticated?
    acceptance = Onboarding::Invite.accept_with_context!(
      token: params[:token],
      password: params[:password],
      authenticated_user: Current.user
    )
    return redirect_to(new_session_path, alert: "That invitation is invalid or has expired.") unless acceptance
    start_new_session_for(acceptance.user) unless Current.user == acceptance.user
    redirect_to root_path(tenant_id: acceptance.tenant.id), notice: "You've joined the team."
  rescue Onboarding::Invite::AlreadyAccepted
    redirect_to new_session_path, alert: "That invitation was already used."
  rescue Onboarding::Invite::AuthenticationRequired => e
    redirect_to accept_invitation_path(token: params[:token]), alert: e.message
  rescue Onboarding::Invite::AlreadyMember => e
    redirect_to root_path, alert: e.message
  rescue ActiveRecord::RecordInvalid => e
    redirect_to accept_invitation_path(token: params[:token]), alert: e.record.errors.full_messages.to_sentence
  end

  def resend
    return head :forbidden unless owner?

    invitation = Invitation.where(tenant_id: Current.tenant.id, accepted_at: nil).find(params[:id])
    if invitation.queue_delivery!
      redirect_to team_path(tenant_id: Current.tenant.id), notice: "Invitation re-queued for #{invitation.email}."
    else
      redirect_to team_path(tenant_id: Current.tenant.id),
        notice: "That invitation is already queued or was sent recently. Try again in a minute."
    end
  end

  private

  def owner?
    Authorization.permits?(user: Current.session.user, tenant_id: Current.tenant.id, capability: "users.manage")
  end
end
