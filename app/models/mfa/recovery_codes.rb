# frozen_string_literal: true

require "digest"
require "securerandom"

module Mfa
  module RecoveryCodes
    COUNT = 10
    ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    module_function

    def generate
      Array.new(COUNT) do
        raw = Array.new(12) { ALPHABET[SecureRandom.random_number(ALPHABET.length)] }.join
        raw.scan(/.{4}/).join("-")
      end
    end

    def digest(code)
      Digest::SHA256.hexdigest("folio-mfa-recovery-v1:#{normalize(code)}")
    end

    def normalize(code)
      code.to_s.upcase.gsub(/[^A-Z0-9]/, "")
    end
  end
end
