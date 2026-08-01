# frozen_string_literal: true

class UserSigningKey < ApplicationRecord
  belongs_to :user

  validates :key_version, :algorithm, :public_key_pem, :encrypted_private_key,
    :fingerprint, presence: true
  validates :key_version, uniqueness: { scope: :user_id },
    numericality: { only_integer: true, greater_than: 0 }
  validates :fingerprint, uniqueness: true, length: { is: 64 }
  validates :algorithm, inclusion: { in: %w[ecdsa-p256-sha256] }
  validates :user_id, uniqueness: { conditions: -> { where(active: true) } }, if: :active?
  validate :key_material_is_immutable, on: :update

  scope :active, -> { where(active: true) }

  private

  def key_material_is_immutable
    changed = will_save_change_to_key_version? || will_save_change_to_algorithm? ||
      will_save_change_to_public_key_pem? || will_save_change_to_encrypted_private_key? ||
      will_save_change_to_fingerprint?
    errors.add(:base, "signing-key material is immutable") if changed
  end
end
