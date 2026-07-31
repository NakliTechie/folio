# frozen_string_literal: true

require "test_helper"

class ApplicationMailerTest < ActionMailer::TestCase
  test "non-production mail uses a reserved invalid sender instead of a real-looking placeholder" do
    message = PasswordsMailer.reset(users(:one))

    assert_equal [ "folio@example.invalid" ], message.from
  end
end
