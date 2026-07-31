# frozen_string_literal: true

require "test_helper"

class SessionTest < ActiveSupport::TestCase
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
