# frozen_string_literal: true

module Mfa
  module Verify
    module_function

    def call(user, candidate, at: Time.current)
      return false unless user.mfa_enabled?
      return true if Totp.valid?(user.mfa_secret, candidate, at: at)

      consume_recovery_code!(user, candidate)
    end

    def consume_recovery_code!(user, candidate)
      candidate_digest = RecoveryCodes.digest(candidate)
      consumed = false
      user.with_lock do
        digests = user.mfa_recovery_code_digests.to_a
        index = digests.index do |stored|
          stored.bytesize == candidate_digest.bytesize &&
            ActiveSupport::SecurityUtils.secure_compare(stored, candidate_digest)
        end
        next unless index

        digests.delete_at(index)
        user.update!(mfa_recovery_code_digests: digests)
        consumed = true
      end
      consumed
    end
  end
end
