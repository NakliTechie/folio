require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Folio
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # The accounting engine is plain Ruby POROs under lib/folio — portable and
    # unit-testable against the conformance corpus without booting Rails.
    # `conformance` is a vendored, read-only package; never autoload it.
    config.autoload_lib(ignore: %w[assets tasks conformance])

    # Postgres-specific DDL (append-only triggers on ledger_events, RLS policies,
    # partial/expression indexes) cannot round-trip through schema.rb.
    config.active_record.schema_format = :sql

    # Money is integer minor units end to end; time is UTC and explicit.
    config.time_zone = "UTC"
    config.active_record.default_timezone = :utc

    # Non-production environments use the reserved .invalid domain. Production overrides this
    # with a required sender identity in config/environments/production.rb.
    config.x.mail_from = "folio@example.invalid"
    config.x.email_verification_required = false
    config.x.mfa_required = false
  end
end
