class User < ApplicationRecord
  MINIMUM_PASSWORD_LENGTH = 15
  TRIVIAL_PASSWORDS = %w[
    passwordpassword password1234567 qwertyuiopasdfg
  ].freeze
  VERIFICATION_DELIVERY_STATES = %w[not_sent queued sending sent failed].freeze
  DELIVERY_COOLDOWN = 1.minute
  DELIVERY_LEASE = 10.minutes

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :memberships, dependent: :destroy
  has_many :tenants, through: :memberships
  has_many :user_office_roles, dependent: :destroy
  has_many :user_signing_keys, dependent: :restrict_with_exception

  after_create -> { EventSigning::KeyProvisioner.ensure!(self) }

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  validates :email_address, presence: true, uniqueness: true, email_address: true
  validates :verification_delivery_state, inclusion: { in: VERIFICATION_DELIVERY_STATES }
  validates :password, length: { minimum: MINIMUM_PASSWORD_LENGTH }, if: -> { password.present? }
  validate :password_is_not_trivial, if: -> { password.present? }
  validate :mfa_configuration_is_complete

  generates_token_for :email_verification, expires_in: 2.days

  def verify! = update!(verified_at: Time.current)
  def verified? = verified_at.present?
  def mfa_enabled? = mfa_enabled_at.present?

  def mfa_secret
    Mfa::Cipher.decrypt(mfa_secret_ciphertext) if mfa_secret_ciphertext.present?
  end

  def enable_mfa!(secret:, recovery_codes:)
    update!(
      mfa_secret_ciphertext: Mfa::Cipher.encrypt(secret),
      mfa_recovery_code_digests: recovery_codes.map { |code| Mfa::RecoveryCodes.digest(code) },
      mfa_enabled_at: Time.current
    )
  end

  def disable_mfa!
    update!(mfa_secret_ciphertext: nil, mfa_recovery_code_digests: [], mfa_enabled_at: nil)
  end

  def enterable_tenants
    Tenant.enterable_by(self)
  end

  def queue_verification_delivery!
    queued = with_lock do
      next false if verified? || active_delivery_lease? || delivery_cooling_down?

      update!(verification_delivery_state: "queued", verification_delivery_attempted_at: Time.current)
      true
    end
    return false unless queued

    !!enqueue_verification_delivery
  end

  def verification_delivery_retryable?
    !verified? && (!active_delivery_lease? || %w[failed not_sent sent].include?(verification_delivery_state))
  end

  private

  def password_is_not_trivial
    normalized = password.to_s.downcase
    return unless TRIVIAL_PASSWORDS.include?(normalized) || normalized.chars.uniq.one?

    errors.add(:password, "is too easy to guess")
  end

  def mfa_configuration_is_complete
    configured = mfa_secret_ciphertext.present? || mfa_enabled_at.present?
    complete = mfa_secret_ciphertext.present? && mfa_enabled_at.present?
    errors.add(:base, "MFA configuration is incomplete") if configured && !complete
  end

  def active_delivery_lease?
    %w[queued sending].include?(verification_delivery_state) &&
      verification_delivery_attempted_at.present? &&
      verification_delivery_attempted_at > DELIVERY_LEASE.ago
  end

  def delivery_cooling_down?
    verification_delivery_attempted_at && verification_delivery_attempted_at > DELIVERY_COOLDOWN.ago
  end


  def enqueue_verification_delivery
    VerificationDeliveryJob.perform_later(id)
  rescue StandardError => e
    with_lock do
      update!(verification_delivery_state: "failed", verification_delivery_attempted_at: Time.current) if
        verification_delivery_state == "queued"
    end
    Rails.error.report(e, handled: true, context: { user_id: id, delivery: "verification" })
    false
  end
end
