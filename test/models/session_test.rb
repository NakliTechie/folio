# frozen_string_literal: true

require "test_helper"

class SessionTest < ActiveSupport::TestCase
  test "expired session metadata is pruned after the retention window" do
    user = User.create!(email_address: "retention@example.com", password: "correct-horse-battery")
    retained = user.sessions.create!(expires_at: 20.days.ago, last_seen_at: 20.days.ago,
      ip_address: "192.0.2.1", user_agent: "retained")
    expired = user.sessions.create!(expires_at: 31.days.ago, last_seen_at: 32.days.ago,
      ip_address: "192.0.2.2", user_agent: "expired")

    assert_equal 1, Session.prune_expired!(at: Time.current)
    assert Session.exists?(retained.id)
    refute Session.exists?(expired.id)
  end

  test "new sessions receive bounded absolute and idle lifetimes" do
    session = users(:one).sessions.create!

    assert_in_delta 24.hours, session.expires_at - session.created_at, 2.seconds
    refute session.expired?(at: session.last_seen_at + 59.minutes)
    assert session.expired?(at: session.last_seen_at + 1.hour)
  end

  test "activity refresh is throttled and never extends absolute expiry" do
    session = users(:one).sessions.create!
    absolute_expiry = session.expires_at
    first_seen = session.last_seen_at

    session.record_activity!(at: first_seen + 1.minute)
    assert_equal first_seen, session.reload.last_seen_at

    session.record_activity!(at: first_seen + 6.minutes)
    assert_equal first_seen + 6.minutes, session.reload.last_seen_at
    assert_equal absolute_expiry, session.expires_at
  end
end
