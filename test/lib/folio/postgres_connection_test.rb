# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/folio/postgres_connection")

class Folio::PostgresConnectionTest < ActiveSupport::TestCase
  test "pg utilities preserve password and verified TLS connection settings" do
    environment = Folio::PostgresConnection.environment(
      password: "secret", sslmode: "verify-full", sslrootcert: "/run/ca.pem",
      sslcert: "/run/client.pem", sslkey: "/run/client.key", channel_binding: "require"
    )

    assert_equal "secret", environment.fetch("PGPASSWORD")
    assert_equal "verify-full", environment.fetch("PGSSLMODE")
    assert_equal "/run/ca.pem", environment.fetch("PGSSLROOTCERT")
    assert_equal "/run/client.pem", environment.fetch("PGSSLCERT")
    assert_equal "/run/client.key", environment.fetch("PGSSLKEY")
    assert_equal "require", environment.fetch("PGCHANNELBINDING")
  end
end
