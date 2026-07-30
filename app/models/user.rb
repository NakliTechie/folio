class User < ApplicationRecord
  VERIFICATION_DELIVERY_STATES = %w[not_sent queued sending sent failed].freeze

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :memberships, dependent: :destroy
  has_many :tenants, through: :memberships
  has_many :user_office_roles, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  validates :email_address, presence: true, uniqueness: true
  validates :verification_delivery_state, inclusion: { in: VERIFICATION_DELIVERY_STATES }

  generates_token_for :email_verification, expires_in: 2.days

  def verify! = update!(verified_at: Time.current)
  def verified? = verified_at.present?

  def queue_verification_delivery!
    update!(verification_delivery_state: "queued")
    VerificationDeliveryJob.perform_later(id)
  end
end
