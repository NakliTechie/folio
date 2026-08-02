# frozen_string_literal: true

require "openssl"
require "securerandom"
require "uri"

module Mfa
  module Totp
    ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    PERIOD = 30
    DIGITS = 6

    module_function

    def generate_secret
      encode_base32(SecureRandom.random_bytes(20))
    end

    def valid?(secret, candidate, at: Time.current, drift: 1)
      value = candidate.to_s.delete(" ")
      return false unless value.match?(/\A\d{#{DIGITS}}\z/)

      counter = at.to_i / PERIOD
      (-drift..drift).any? do |offset|
        ActiveSupport::SecurityUtils.secure_compare(code(secret, counter: counter + offset), value)
      end
    rescue ArgumentError
      false
    end

    def provisioning_uri(secret:, email:, issuer: "Folio")
      label = URI.encode_www_form_component("#{issuer}:#{email}")
      query = URI.encode_www_form(secret: secret, issuer: issuer, algorithm: "SHA1",
        digits: DIGITS, period: PERIOD)
      "otpauth://totp/#{label}?#{query}"
    end

    def code(secret, counter: Time.current.to_i / PERIOD)
      digest = OpenSSL::HMAC.digest("SHA1", decode_base32(secret), [ counter ].pack("Q>"))
      offset = digest.getbyte(-1) & 0x0f
      binary = digest.byteslice(offset, 4).unpack1("N") & 0x7fffffff
      (binary % (10**DIGITS)).to_s.rjust(DIGITS, "0")
    end

    def encode_base32(bytes)
      bits = bytes.unpack1("B*")
      bits.scan(/.{1,5}/).map do |group|
        ALPHABET[group.ljust(5, "0").to_i(2)]
      end.join
    end

    def decode_base32(value)
      normalized = value.to_s.upcase.delete("= \t\r\n-")
      raise ArgumentError, "invalid base32 secret" unless normalized.match?(/\A[A-Z2-7]+\z/)

      bits = normalized.chars.map { |character| ALPHABET.index(character).to_s(2).rjust(5, "0") }.join
      bits.scan(/.{8}/).map { |byte| byte.to_i(2) }.pack("C*")
    end
  end
end
