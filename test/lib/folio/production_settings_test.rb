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
      "FOLIO_ALLOWED_HOSTS" => "books.acme.test,internal.acme.test"
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
end
