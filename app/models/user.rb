class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :memberships, dependent: :destroy
  has_many :tenants, through: :memberships
  has_many :user_office_roles, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  validates :email_address, presence: true, uniqueness: true

  generates_token_for :email_verification, expires_in: 2.days

  def verify! = update!(verified_at: Time.current)
  def verified? = verified_at.present?
end
