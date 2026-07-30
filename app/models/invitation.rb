# frozen_string_literal: true

# An invite for an email to join a tenant with a role. The signed token proves the invitee
# controls the invited email; accepted_at makes it single-use.
class Invitation < ApplicationRecord
  DELIVERY_STATES = %w[not_sent queued sending sent failed].freeze

  belongs_to :tenant
  belongs_to :invited_by, class_name: "User", optional: true

  ROLE_CODES = %w[owner accountant operator ca_auditor viewer].freeze

  normalizes :email, with: ->(e) { e.strip.downcase }
  validates :email, :role_code, presence: true
  validates :role_code, inclusion: { in: ROLE_CODES }
  validates :delivery_state, inclusion: { in: DELIVERY_STATES }
  validates :email, uniqueness: {
    scope: :tenant_id,
    conditions: -> { where(accepted_at: nil) },
    message: "already has a pending invitation"
  }

  generates_token_for :invite, expires_in: 7.days

  def pending? = accepted_at.nil?

  def queue_delivery!
    update!(delivery_state: "queued")
    InvitationDeliveryJob.perform_later(id)
  end
end
