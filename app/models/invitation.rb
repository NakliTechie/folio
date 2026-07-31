# frozen_string_literal: true

# An invite for an email to join a tenant with a role. The signed token proves the invitee
# controls the invited email; accepted_at makes it single-use.
class Invitation < ApplicationRecord
  DELIVERY_STATES = %w[not_sent queued sending sent failed].freeze
  DELIVERY_COOLDOWN = 1.minute
  DELIVERY_LEASE = 10.minutes

  belongs_to :tenant
  belongs_to :invited_by, class_name: "User", optional: true

  ROLE_CODES = %w[owner accountant operator ca_auditor viewer].freeze

  normalizes :email, with: ->(e) { e.strip.downcase }
  validates :email, :role_code, presence: true
  validates :email, email_address: true
  validates :role_code, inclusion: { in: ROLE_CODES }
  validates :delivery_state, inclusion: { in: DELIVERY_STATES }
  validates :email, uniqueness: {
    scope: :tenant_id,
    conditions: -> { where(accepted_at: nil) },
    message: "already has a pending invitation"
  }
  validate :email_is_not_already_a_member, on: :create

  generates_token_for :invite, expires_in: 7.days

  def pending? = accepted_at.nil?

  def queue_delivery!
    queued = with_lock do
      next false unless pending?
      next false if active_delivery_lease?
      next false if delivery_attempted_at && delivery_attempted_at > DELIVERY_COOLDOWN.ago

      update!(delivery_state: "queued", delivery_attempted_at: Time.current)
      true
    end
    return false unless queued

    !!enqueue_delivery
  end

  def delivery_retryable?
    pending? && (!active_delivery_lease? || %w[failed not_sent sent].include?(delivery_state))
  end

  private

  def email_is_not_already_a_member
    return if email.blank? || tenant_id.blank?

    user_id = User.where(email_address: email).pick(:id)
    errors.add(:email, "already belongs to this company; change their role instead") if
      user_id && Membership.exists?(tenant_id: tenant_id, user_id: user_id)
  end

  def active_delivery_lease?
    %w[queued sending].include?(delivery_state) && delivery_attempted_at.present? &&
      delivery_attempted_at > DELIVERY_LEASE.ago
  end

  def enqueue_delivery
    InvitationDeliveryJob.perform_later(id)
  rescue StandardError => e
    with_lock do
      update!(delivery_state: "failed", delivery_attempted_at: Time.current) if delivery_state == "queued"
    end
    Rails.error.report(e, handled: true, context: { invitation_id: id, delivery: "invitation" })
    false
  end
end
