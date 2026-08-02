# frozen_string_literal: true

require "test_helper"

class MfaTotpTest < ActiveSupport::TestCase
  test "TOTP matches the RFC 6238 SHA1 vector truncated to six digits" do
    secret = Mfa::Totp.encode_base32("12345678901234567890")

    assert_equal "287082", Mfa::Totp.code(secret, counter: 1)
    assert Mfa::Totp.valid?(secret, "287082", at: Time.at(59), drift: 0)
    refute Mfa::Totp.valid?(secret, "287083", at: Time.at(59), drift: 0)
  end

  test "recovery codes are high-entropy one-time credentials" do
    codes = Mfa::RecoveryCodes.generate

    assert_equal 10, codes.size
    assert_equal codes.size, codes.uniq.size
    assert codes.all? { |code| code.match?(/\A[A-Z2-9]{4}(?:-[A-Z2-9]{4}){2}\z/) }
    assert_equal Mfa::RecoveryCodes.digest(codes.first.delete("-")),
      Mfa::RecoveryCodes.digest(codes.first.downcase)
  end
end
