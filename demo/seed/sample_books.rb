# frozen_string_literal: true

require "yaml"

module Folio
  # Stable entry point shared by demos, walkthroughs, guides, and tests. The manifest is the
  # human-readable scenario catalogue; SampleBooks remains the domain-service-backed generator.
  module DemoSeed
    Error = Class.new(StandardError)
    MANIFEST_PATH = File.expand_path("sample_books.yml", __dir__)

    module_function

    def manifest
      @manifest ||= YAML.safe_load_file(MANIFEST_PATH, aliases: false).deep_stringify_keys.freeze
    end

    def scenarios
      manifest.fetch("scenarios")
    end

    def scenario_codes
      scenarios.keys.freeze
    end

    def default_scenario
      manifest.fetch("default")
    end

    def load!(scenario: default_scenario, email:, password:)
      verify_contract!
      code = scenario.to_s
      unless scenarios.key?(code)
        raise Error, "unknown demo scenario #{code.inspect} — known: #{scenario_codes.join(', ')}"
      end

      Folio::SampleBooks.seed!(scenario: code, email: email, password: password)
    end

    def verify_contract!
      manifest_codes = scenario_codes.sort
      generator_codes = Folio::SampleBooks::SCENARIOS.keys.sort
      return true if manifest_codes == generator_codes && scenarios.key?(default_scenario)

      raise Error, "demo seed manifest and generator scenarios are out of sync"
    end
  end
end
