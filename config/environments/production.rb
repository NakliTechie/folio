require "active_support/core_ext/integer/time"

Rails.application.configure do
  app_host = ENV.fetch("FOLIO_APP_HOST")
  mail_from = ENV.fetch("FOLIO_MAIL_FROM")
  smtp_address = ENV.fetch("FOLIO_SMTP_ADDRESS")
  smtp_username = ENV.fetch("FOLIO_SMTP_USERNAME")
  smtp_password = ENV.fetch("FOLIO_SMTP_PASSWORD")

  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

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
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  # config.cache_store = :mem_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  config.x.mail_from = mail_from
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.perform_deliveries = true
  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.default_url_options = { host: app_host, protocol: "https" }
  config.action_mailer.smtp_settings = {
    address: smtp_address,
    port: Integer(ENV.fetch("FOLIO_SMTP_PORT", "587")),
    domain: ENV.fetch("FOLIO_SMTP_DOMAIN", app_host),
    user_name: smtp_username,
    password: smtp_password,
    authentication: ENV.fetch("FOLIO_SMTP_AUTHENTICATION", "plain").to_sym,
    enable_starttls_auto: true,
    open_timeout: Integer(ENV.fetch("FOLIO_SMTP_OPEN_TIMEOUT", "5")),
    read_timeout: Integer(ENV.fetch("FOLIO_SMTP_READ_TIMEOUT", "5"))
  }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Exact host allowlisting blocks DNS rebinding. A comma-separated override supports an
  # additional internal/custom hostname without accepting arbitrary subdomains.
  config.hosts = ENV.fetch("FOLIO_ALLOWED_HOSTS", app_host).split(",").map(&:strip).reject(&:empty?)
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
