# frozen_string_literal: true

require "uri"

module Folio
  class ProductionSettings
    InvalidConfiguration = Class.new(StandardError)
    REQUIRED = %w[
      FOLIO_APP_HOST FOLIO_MAIL_FROM FOLIO_SMTP_ADDRESS
      FOLIO_SMTP_USERNAME FOLIO_SMTP_PASSWORD
    ].freeze
    AUTHENTICATION_METHODS = %w[plain login cram_md5].freeze
    PLACEHOLDER = /(localhost|\.invalid\z|example\.|changeme|placeholder|your[-_.])/i
    HOST = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/i
    EMAIL = URI::MailTo::EMAIL_REGEXP

    attr_reader :app_host, :mail_from, :smtp_address, :smtp_username, :smtp_password,
      :smtp_port, :smtp_domain, :smtp_authentication, :smtp_open_timeout,
      :smtp_read_timeout, :allowed_hosts

    def self.load!(environment = ENV)
      new(environment).tap(&:validate!)
    end

    def initialize(environment)
      @environment = environment
      @app_host = value("FOLIO_APP_HOST")
      @mail_from = value("FOLIO_MAIL_FROM")
      @smtp_address = value("FOLIO_SMTP_ADDRESS")
      @smtp_username = value("FOLIO_SMTP_USERNAME")
      @smtp_password = value("FOLIO_SMTP_PASSWORD")
      @smtp_port = integer("FOLIO_SMTP_PORT", "587")
      @smtp_domain = value("FOLIO_SMTP_DOMAIN", @app_host)
      @smtp_authentication = value("FOLIO_SMTP_AUTHENTICATION", "plain")
      @smtp_open_timeout = integer("FOLIO_SMTP_OPEN_TIMEOUT", "5")
      @smtp_read_timeout = integer("FOLIO_SMTP_READ_TIMEOUT", "5")
      @allowed_hosts = value("FOLIO_ALLOWED_HOSTS", @app_host).to_s.split(",").map(&:strip).reject(&:empty?)
    end

    def validate!
      missing = REQUIRED.select { |name| value(name).empty? }
      fail_with("required settings are blank: #{missing.join(', ')}") if missing.any?
      validate_host!(app_host, "FOLIO_APP_HOST")
      validate_host!(smtp_address, "FOLIO_SMTP_ADDRESS")
      validate_host!(smtp_domain, "FOLIO_SMTP_DOMAIN")
      fail_with("FOLIO_MAIL_FROM must be a real email address") unless mail_from.match?(EMAIL) && !placeholder?(mail_from)
      fail_with("SMTP credentials must not be placeholders") if placeholder?(smtp_username) || placeholder?(smtp_password)
      fail_with("FOLIO_SMTP_PORT must be between 1 and 65535") unless (1..65_535).cover?(smtp_port)
      unless AUTHENTICATION_METHODS.include?(smtp_authentication)
        fail_with("FOLIO_SMTP_AUTHENTICATION must be one of #{AUTHENTICATION_METHODS.join(', ')}")
      end
      fail_with("SMTP timeouts must be positive") unless smtp_open_timeout.positive? && smtp_read_timeout.positive?
      fail_with("FOLIO_ALLOWED_HOSTS must contain at least one exact host") if allowed_hosts.empty?
      allowed_hosts.each { |host| validate_host!(host, "FOLIO_ALLOWED_HOSTS") }
      fail_with("FOLIO_ALLOWED_HOSTS must include FOLIO_APP_HOST") unless allowed_hosts.include?(app_host)
      self
    end

    def smtp_settings
      {
        address: smtp_address,
        port: smtp_port,
        domain: smtp_domain,
        user_name: smtp_username,
        password: smtp_password,
        authentication: smtp_authentication.to_sym,
        enable_starttls: true,
        enable_starttls_auto: false,
        openssl_verify_mode: "peer",
        open_timeout: smtp_open_timeout,
        read_timeout: smtp_read_timeout
      }
    end

    private

    def value(name, fallback = nil)
      @environment.fetch(name, fallback).to_s.strip
    end

    def integer(name, fallback)
      Integer(value(name, fallback), 10)
    rescue ArgumentError
      fail_with("#{name} must be an integer")
    end

    def validate_host!(host, name)
      fail_with("#{name} must be a real hostname without a scheme or path") if
        host.empty? || !host.match?(HOST) || placeholder?(host)
    end

    def placeholder?(value)
      value.to_s.match?(PLACEHOLDER)
    end

    def fail_with(message)
      raise InvalidConfiguration, "Invalid production configuration: #{message}"
    end
  end
end
