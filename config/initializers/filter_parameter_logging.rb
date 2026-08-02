# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :name, :phone, :address, :gstin, :tan, :pan, :narration, :external_reference,
  :supplier_invoice, :quantity, :unit_price, :reviewed_itc, :reviewed_turnover,
  :tax_registration, :party_snapshot, :provider_response, :signed_invoice,
  :signed_qr_code, :tds, :remarks, :mfa, :recovery_code
]
