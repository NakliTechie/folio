class User < ApplicationRecord
  MINIMUM_PASSWORD_LENGTH = 15
  TRIVIAL_PASSWORDS = %w[
    passwordpassword password1234567 qwertyuiopasdfg
  ].freeze
  VERIFICATION_DELIVERY_STATES = %w[not_sent queued sending sent failed].freeze
  DELIVERY_COOLDOWN = 1.minute

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :memberships, dependent: :destroy
  has_many :tenants, through: :memberships
  has_many :user_office_roles, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  validates :email_address, presence: true, uniqueness: true
  validates :verification_delivery_state, inclusion: { in: VERIFICATION_DELIVERY_STATES }
  validates :password, length: { minimum: MINIMUM_PASSWORD_LENGTH }, if: -> { password.present? }
  validate :password_is_not_trivial, if: -> { password.present? }

  generates_token_for :email_verification, expires_in: 2.days

  def verify! = update!(verified_at: Time.current)
  def verified? = verified_at.present?

  def queue_verification_delivery!
    queued = with_lock do
      next false if verified? || delivery_in_flight? || delivery_cooling_down?

      update!(verification_delivery_state: "queued", verification_delivery_attempted_at: Time.current)
      true
    end
    VerificationDeliveryJob.perform_later(id) if queued
    queued
  end

  private

  def password_is_not_trivial
    normalized = password.to_s.downcase
    return unless TRIVIAL_PASSWORDS.include?(normalized) || normalized.chars.uniq.one?

    errors.add(:password, "is too easy to guess")
  end

  def delivery_in_flight?
    %w[queued sending].include?(verification_delivery_state)
  end

  def delivery_cooling_down?
    verification_delivery_attempted_at && verification_delivery_attempted_at > DELIVERY_COOLDOWN.ago
  end
end
