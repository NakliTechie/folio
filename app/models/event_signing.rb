# frozen_string_literal: true

module EventSigning
  Result = Data.define(:signature, :key)

  module_function

  def sign(user_id:, hash_hex:)
    key_record = UserSigningKey.active.find_by(user_id: user_id)
    return unless key_record

    private_key = OpenSSL::PKey.read(Cipher.decrypt(key_record.encrypted_private_key))
    digest = [ valid_hash!(hash_hex) ].pack("H*")
    Result.new(private_key.sign_raw(nil, digest), key_record)
  end

  def sign!(user_id:, hash_hex:)
    sign(user_id: user_id, hash_hex: hash_hex) ||
      raise("User #{user_id} has no active event-signing key")
  end

  def verify(event)
    if event.respond_to?(:external_signing_key_id) && event.external_signing_key_id
      key = ExternalSigningKey.find_by(id: event.external_signing_key_id, tenant_id: event.tenant_id)
      return false unless key

      return Khata::Signatures.verify(
        hash_hex: event.hash_hex, signature: event.signature, jwk: key.public_key_jwk
      )
    end
    return false if event.signature.blank? || event.signing_key_id.blank?

    key_record = UserSigningKey.find_by(id: event.signing_key_id, user_id: event.actor_user_id)
    return false unless key_record

    public_key = OpenSSL::PKey.read(key_record.public_key_pem)
    public_key.verify_raw(nil, event.signature, [ valid_hash!(event.hash_hex) ].pack("H*"))
  rescue OpenSSL::PKey::PKeyError, ArgumentError
    false
  end

  def valid_hash!(hash_hex)
    value = hash_hex.to_s
    raise ArgumentError, "event hash must be 32-byte lowercase hex" unless value.match?(/\A[0-9a-f]{64}\z/)

    value
  end

  module Cipher
    module_function

    def encrypt(plaintext)
      encryptor.encrypt_and_sign(plaintext)
    end

    def decrypt(ciphertext)
      encryptor.decrypt_and_verify(ciphertext)
    end

    def encryptor
      key = Rails.application.key_generator.generate_key("folio-user-event-signing-v1", 32)
      ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm")
    end
  end

  module KeyProvisioner
    module_function

    def ensure!(user)
      UserSigningKey.active.find_by(user_id: user.id) || provision!(user)
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def provision!(user)
      private_key = OpenSSL::PKey::EC.generate("prime256v1")
      public_pem = private_key.public_to_pem
      UserSigningKey.create!(
        user: user,
        key_version: UserSigningKey.where(user_id: user.id).maximum(:key_version).to_i + 1,
        algorithm: "ecdsa-p256-sha256",
        public_key_pem: public_pem,
        encrypted_private_key: Cipher.encrypt(private_key.private_to_pem),
        fingerprint: Digest::SHA256.hexdigest(public_pem),
        active: true
      )
    end
  end
end
