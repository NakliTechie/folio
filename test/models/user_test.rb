# frozen_string_literal: true

require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")

    assert_equal "downcased@example.com", user.email_address
  end

  test "new passwords require at least fifteen characters" do
    user = User.new(email_address: "short-password@example.com", password: "too-short")

    assert_not user.valid?
    assert_includes user.errors[:password], "is too short (minimum is 15 characters)"
  end

  test "trivially repeated passwords are rejected even when long enough" do
    user = User.new(email_address: "trivial-password@example.com", password: "a" * 20)

    assert_not user.valid?
    assert_includes user.errors[:password], "is too easy to guess"
  end

  test "long passphrases are accepted without composition rules" do
    user = User.new(email_address: "passphrase@example.com", password: "four calm ledger words")

    assert user.valid?
  end
end
