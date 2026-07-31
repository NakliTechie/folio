# frozen_string_literal: true

module Taxes
  module India
    # Offline GSTIN structure and checksum validation. This proves input consistency; it does not
    # claim that GSTN has issued the identifier or that the registration is currently active.
    module Gstin
      ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      FORMAT = /\A\d{2}[A-Z]{5}\d{4}[A-Z][1-9A-Z]Z[0-9A-Z]\z/

      module_function

      def normalize(value) = value.to_s.strip.upcase

      def valid?(value)
        gstin = normalize(value)
        return false unless gstin.match?(FORMAT)
        return false unless StateCodes.valid?(gstin.first(2))

        checksum(gstin.first(14)) == gstin.last
      end

      def state_code(value)
        gstin = normalize(value)
        gstin.first(2) if valid?(gstin)
      end

      def checksum(first_fourteen)
        input = normalize(first_fourteen)
        raise ArgumentError, "GSTIN checksum input must contain fourteen alphanumeric characters" unless
          input.match?(/\A[0-9A-Z]{14}\z/)

        factor = 2
        sum = input.chars.reverse.sum do |character|
          addend = factor * ALPHABET.index(character)
          factor = factor == 2 ? 1 : 2
          (addend / 36) + (addend % 36)
        end
        ALPHABET[(36 - (sum % 36)) % 36]
      end
    end
  end
end
