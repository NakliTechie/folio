# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/folio/production_settings")

class Folio::ProductionSettingsTest < ActiveSupport::TestCase
  setup do
    @environment = {
      "FOLIO_APP_HOST" => "books.acme.test",
      "FOLIO_MAIL_FROM" => "accounts@acme.test",
      "FOLIO_SMTP_ADDRESS" => "smtp.acme.test",
      "FOLIO_SMTP_USERNAME" => "folio-account",
      "FOLIO_SMTP_PASSWORD" => "provider-secret",
      "FOLIO_ALLOWED_HOSTS" => "books.acme.test,internal.acme.test",
      "SECRET_KEY_BASE" => "s" * 64,
      "DATABASE_URL" => "postgresql://folio:secret@db.acme.test/folio_primary?sslmode=verify-full",
      "QUEUE_DATABASE_URL" => "postgresql://folio:secret@db.acme.test/folio_queue?sslmode=verify-full",
      "CACHE_DATABASE_URL" => "postgresql://folio:secret@db.acme.test/folio_cache?sslmode=verify-full"
    }
  end

  test "loads typed nonblank production settings and exact hosts" do
    settings = Folio::ProductionSettings.load!(@environment)

    assert_equal "books.acme.test", settings.app_host
    assert_equal 587, settings.smtp_port
    assert_equal %w[books.acme.test internal.acme.test], settings.allowed_hosts
    assert_equal "plain", settings.smtp_authentication
    assert_equal true, settings.smtp_settings.fetch(:enable_starttls)
    assert_equal false, settings.smtp_settings.fetch(:enable_starttls_auto)
    assert_equal "peer", settings.smtp_settings.fetch(:openssl_verify_mode)
  end

  test "rejects blank placeholder malformed and incomplete settings" do
    assert_raises(Folio::ProductionSettings::InvalidConfiguration) do
      Folio::ProductionSettings.load!(@environment.merge("FOLIO_SMTP_PASSWORD" => " "))
    end
    assert_raises(Folio::ProductionSettings::InvalidConfiguration) do
      Folio::ProductionSettings.load!(@environment.merge("FOLIO_APP_HOST" => "localhost"))
    end

    error = assert_raises(Folio::ProductionSettings::InvalidConfiguration) do
      Folio::ProductionSettings.load!(@environment.merge("FOLIO_ALLOWED_HOSTS" => "internal.acme.test"))
    end
    assert_match(/must include FOLIO_APP_HOST/, error.message)
  end

  test "rejects malformed numeric and authentication choices" do
    assert_raises(Folio::ProductionSettings::InvalidConfiguration) do
      Folio::ProductionSettings.load!(@environment.merge("FOLIO_SMTP_PORT" => "zero"))
    end
    assert_raises(Folio::ProductionSettings::InvalidConfiguration) do
      Folio::ProductionSettings.load!(@environment.merge("FOLIO_SMTP_AUTHENTICATION" => "anything"))
    end
  end

  test "requires a signing strategy and three distinct databases" do
    assert_raises(Folio::ProductionSettings::InvalidConfiguration) do
      Folio::ProductionSettings.load!(@environment.except("SECRET_KEY_BASE"))
    end
    assert_raises(Folio::ProductionSettings::InvalidConfiguration) do
      Folio::ProductionSettings.load!(@environment.except("CACHE_DATABASE_URL"))
    end

    error = assert_raises(Folio::ProductionSettings::InvalidConfiguration) do
      Folio::ProductionSettings.load!(
        @environment.merge("CACHE_DATABASE_URL" => @environment.fetch("QUEUE_DATABASE_URL"))
      )
    end
    assert_match(/three distinct databases/, error.message)
  end

  test "requires explicit verified TLS for remote PostgreSQL URLs" do
    no_tls = @environment.transform_values { |value| value.to_s.sub("?sslmode=verify-full", "") }
    error = assert_raises(Folio::ProductionSettings::InvalidConfiguration) do
      Folio::ProductionSettings.load!(no_tls)
    end
    assert_match(/sslmode explicitly/, error.message)

    weak = @environment.transform_values { |value| value.to_s.sub("verify-full", "require") }
    error = assert_raises(Folio::ProductionSettings::InvalidConfiguration) do
      Folio::ProductionSettings.load!(weak)
    end
    assert_match(/verify-full/, error.message)

    local = @environment.transform_values do |value|
      value.to_s.gsub("db.acme.test", "localhost").sub("verify-full", "disable")
    end
    assert Folio::ProductionSettings.load!(local)
  end
end
