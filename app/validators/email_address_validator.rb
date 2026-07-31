# frozen_string_literal: true

# A deliberately conservative ASCII email boundary. Folio does not currently advertise
# SMTPUTF8/internationalized local-part support, so accepting those addresses would promise
# delivery behavior that the configured mail transport may not provide.
class EmailAddressValidator < ActiveModel::EachValidator
  MAX_LENGTH = 254
  FORMAT = /\A[a-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/i

  def validate_each(record, attribute, value)
    return if value.blank?

    record.errors.add(attribute, "is too long (maximum is #{MAX_LENGTH} characters)") if value.length > MAX_LENGTH
    record.errors.add(attribute, "is not a valid email address") unless FORMAT.match?(value)
  end
end
