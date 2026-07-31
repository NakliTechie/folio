class Session < ApplicationRecord
  ABSOLUTE_LIFETIME = 24.hours
  IDLE_TIMEOUT = 1.hour
  ACTIVITY_WRITE_INTERVAL = 5.minutes

  belongs_to :user

  before_validation :set_lifetime, on: :create

  scope :active_at, ->(time = Time.current) {
    where("expires_at > ? AND last_seen_at > ?", time, time - IDLE_TIMEOUT)
  }

  def expired?(at: Time.current)
    expires_at.blank? || last_seen_at.blank? || expires_at <= at || last_seen_at <= at - IDLE_TIMEOUT
  end

  def record_activity!(at: Time.current)
    return if last_seen_at && last_seen_at > at - ACTIVITY_WRITE_INTERVAL

    update_column(:last_seen_at, at)
  end

  private

  def set_lifetime
    self.last_seen_at ||= Time.current
    self.expires_at ||= Time.current + ABSOLUTE_LIFETIME
  end
end
