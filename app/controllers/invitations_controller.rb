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
    InvitationsMailer.invite(inv).deliver_later
    redirect_to root_path, notice: "Invitation sent to #{inv.email}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to root_path, alert: e.record.errors.full_messages.to_sentence
  end

  def accept
    @invitation = Invitation.find_by_token_for(:invite, params[:token])
    return redirect_to(new_session_path, alert: "That invitation is invalid or has expired.") unless @invitation&.pending?
    @token = params[:token]
  end

  def do_accept
    user = Onboarding::Invite.accept!(token: params[:token], password: params[:password])
    return redirect_to(new_session_path, alert: "That invitation is invalid or has expired.") unless user
    start_new_session_for user
    redirect_to root_path, notice: "You've joined the team."
  rescue Onboarding::Invite::AlreadyAccepted
    redirect_to new_session_path, alert: "That invitation was already used."
  end

  private

  def owner?
    Authorization.permits?(user: Current.session.user, tenant_id: Current.tenant.id, capability: "users.manage")
  end
end
