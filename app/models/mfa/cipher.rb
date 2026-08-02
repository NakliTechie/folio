# frozen_string_literal: true

module Mfa
  module Cipher
    module_function

    def encrypt(plaintext) = encryptor.encrypt_and_sign(plaintext)
    def decrypt(ciphertext) = encryptor.decrypt_and_verify(ciphertext)

    def encryptor
      key = Rails.application.key_generator.generate_key("folio-user-mfa-v1", 32)
      ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm")
    end
  end
end
