# frozen_string_literal: true

module Folio
  module PostgresConnection
    ENVIRONMENT_KEYS = {
      password: "PGPASSWORD", sslmode: "PGSSLMODE", sslrootcert: "PGSSLROOTCERT",
      sslcert: "PGSSLCERT", sslkey: "PGSSLKEY", sslcrl: "PGSSLCRL",
      channel_binding: "PGCHANNELBINDING", gssencmode: "PGGSSENCMODE"
    }.freeze

    module_function

    def environment(configuration)
      config = configuration.symbolize_keys
      ENVIRONMENT_KEYS.each_with_object({}) do |(key, variable), result|
        result[variable] = config[key].to_s if config[key].present?
      end
    end
  end
end
