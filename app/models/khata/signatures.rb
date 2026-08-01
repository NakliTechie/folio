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
      raw_signature = decoded_signature(signature)
      digest = [ EventSigning.valid_hash!(hash_hex) ].pack("H*")
      key = public_key(jwk)
      if raw_signature&.bytesize == 64
        key.verify("SHA256", p1363_to_der(raw_signature), digest)
      else
        raw_signature.present? && key.verify_raw(nil, raw_signature, digest)
      end
    rescue ArgumentError, OpenSSL::PKey::PKeyError, OpenSSL::ASN1::ASN1Error
      false
    end

    def jwk_from_pem(public_key_pem)
      key = OpenSSL::PKey.read(public_key_pem)
      point = key.public_key.to_octet_string(:uncompressed)
      raise ArgumentError, "signing key must be an EC P-256 public key" unless point.bytesize == 65

      {
        "kty" => "EC", "crv" => "P-256",
        "x" => Base64.urlsafe_encode64(point.byteslice(1, 32), padding: false),
        "y" => Base64.urlsafe_encode64(point.byteslice(33, 32), padding: false),
        "ext" => true, "key_ops" => [ "verify" ]
      }
    rescue OpenSSL::PKey::PKeyError, NoMethodError
      raise ArgumentError, "signing key must be an EC P-256 public key"
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

    def decoded_signature(signature)
      return signature unless signature.is_a?(String)
      return signature if signature.bytesize == 64
      return signature if signature.encoding == Encoding::BINARY && !signature.ascii_only?

      Base64.strict_decode64(signature)
    rescue ArgumentError
      signature
    end
  end
end
