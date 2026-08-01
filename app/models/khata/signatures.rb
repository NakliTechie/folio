# frozen_string_literal: true

require "base64"
require "digest"
require "openssl"

module Khata
  module Signatures
    module_function

    def fingerprint(jwk)
      Digest::SHA256.hexdigest(Folio::KhataHash.canonical_payload(jwk.slice("crv", "kty", "x", "y")))
    end

    def verify(hash_hex:, signature:, jwk:)
      raw_signature = if signature.is_a?(String) && signature.bytesize == 64
        signature
      elsif signature.is_a?(String)
        Base64.strict_decode64(signature)
      else
        signature
      end
      return false unless raw_signature&.bytesize == 64

      public_key(jwk).verify(
        "SHA256", p1363_to_der(raw_signature), [ EventSigning.valid_hash!(hash_hex) ].pack("H*")
      )
    rescue ArgumentError, OpenSSL::PKey::PKeyError, OpenSSL::ASN1::ASN1Error
      false
    end

    def public_key(jwk)
      unless jwk.is_a?(Hash) && jwk["kty"] == "EC" && jwk["crv"] == "P-256"
        raise ArgumentError, ".khata signing key must be an EC P-256 JWK"
      end
      point = "\x04".b + base64url(jwk.fetch("x")) + base64url(jwk.fetch("y"))
      raise ArgumentError, ".khata signing key coordinates must each be 32 bytes" unless point.bytesize == 65

      algorithm = OpenSSL::ASN1::Sequence([
        OpenSSL::ASN1::ObjectId("id-ecPublicKey"),
        OpenSSL::ASN1::ObjectId("prime256v1")
      ])
      OpenSSL::PKey.read(OpenSSL::ASN1::Sequence([
        algorithm, OpenSSL::ASN1::BitString(point)
      ]).to_der)
    end

    def p1363_to_der(signature)
      half = signature.bytesize / 2
      OpenSSL::ASN1::Sequence([
        OpenSSL::ASN1::Integer(OpenSSL::BN.new(signature.byteslice(0, half), 2)),
        OpenSSL::ASN1::Integer(OpenSSL::BN.new(signature.byteslice(half, half), 2))
      ]).to_der
    end

    def base64url(value)
      Base64.urlsafe_decode64(value.to_s + ("=" * ((4 - value.to_s.length % 4) % 4)))
    end
  end
end
