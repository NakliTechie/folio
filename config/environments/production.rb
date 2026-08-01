require "active_support/core_ext/integer/time"
require_relative "../../lib/folio/production_settings"
require_relative "../../lib/folio/json_log_formatter"

Rails.application.configure do
  settings = Folio::ProductionSettings.load!
  app_host = settings.app_host

  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true
  config.cache_store = :solid_cache_store

  # A verified mailbox is required before an authenticated user can mutate company state.
  config.x.email_verification_required = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # The supported production topology terminates TLS at a trusted reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  config.ssl_options = {
    hsts: { expires: 1.year, subdomains: true },
    redirect: { exclude: ->(request) { request.path == "/up" } }
  }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  stdout_logger = ActiveSupport::Logger.new(STDOUT)
  stdout_logger.formatter = Folio::JsonLogFormatter.new
  config.logger = ActiveSupport::TaggedLogging.new(stdout_logger)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  config.x.mail_from = settings.mail_from
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.perform_deliveries = true
  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.default_url_options = { host: app_host, protocol: "https" }
  config.action_mailer.smtp_settings = settings.smtp_settings

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Exact host allowlisting blocks DNS rebinding. A comma-separated override supports an
  # additional internal/custom hostname without accepting arbitrary subdomains.
  config.hosts = settings.allowed_hosts
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
