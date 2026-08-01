# frozen_string_literal: true

module Taxes
  module India
    module Gst
      module EInvoice
        # Normalized provider boundary. Concrete GSP/IRP adapters translate their wire formats
        # into Acknowledgement or raise Rejection/TransportError. Tokens never cross this seam.
        module Provider
          Acknowledgement = Data.define(
            :irn, :ack_number, :acknowledged_at, :signed_invoice, :signed_qr_code,
            :raw_response, :signature_status
          )
          CancellationAcknowledgement = Data.define(:irn, :cancelled_at, :raw_response)
          IrnStatus = Data.define(:irn, :status, :cancelled_at, :raw_response)

          class Error < StandardError
            attr_reader :code, :raw_response

            def initialize(message, code: nil, raw_response: nil)
              super(message)
              @code = code
              @raw_response = raw_response
            end
          end

          ConfigurationError = Class.new(Error)
          TransportError = Class.new(Error)
          Rejection = Class.new(Error)

          module Contract
            def name = raise NotImplementedError
            def configured? = raise NotImplementedError

            def generate_irn(payload:, request_id:)
              raise NotImplementedError
            end

            # Used after an ambiguous transport failure; adapters must query by statutory
            # document identity instead of blindly generating the same IRN again.
            def fetch_by_document(seller_gstin:, document_type:, document_number:, document_date:)
              raise NotImplementedError
            end

            def cancel_irn(irn:, reason_code:, remarks:, request_id:)
              raise NotImplementedError
            end

            # Used after an ambiguous cancellation. Returns normalized active/cancelled state;
            # adapters must not infer cancellation from an HTTP timeout.
            def fetch_by_irn(irn:)
              raise NotImplementedError
            end
          end

          module_function

          def validate_acknowledgement!(acknowledgement)
            unless acknowledgement.is_a?(Acknowledgement)
              raise InvalidPayload, "IRP adapter returned an unsupported acknowledgement"
            end
            unless acknowledgement.irn.to_s.match?(/\A[0-9a-fA-F]{64}\z/)
              raise InvalidPayload, "IRP acknowledgement has an invalid IRN"
            end
            unless acknowledgement.ack_number.to_s.match?(/\A\d{1,20}\z/)
              raise InvalidPayload, "IRP acknowledgement number is invalid"
            end
            unless acknowledgement.acknowledged_at.respond_to?(:iso8601)
              raise InvalidPayload, "IRP acknowledgement time is invalid"
            end
            if acknowledgement.signed_invoice.blank? || acknowledgement.signed_qr_code.blank?
              raise InvalidPayload, "IRP signed invoice and signed QR artifacts are required"
            end
            unless %w[provider_verified locally_verified].include?(acknowledgement.signature_status)
              raise InvalidPayload, "IRP acknowledgement signature has not been verified"
            end
            unless acknowledgement.raw_response.is_a?(Hash)
              raise InvalidPayload, "IRP raw response must be retained as an object"
            end
            acknowledgement
          end

          def validate_cancellation_acknowledgement!(acknowledgement)
            unless acknowledgement.is_a?(CancellationAcknowledgement) &&
                   acknowledgement.irn.to_s.match?(/\A[0-9a-fA-F]{64}\z/) &&
                   acknowledgement.cancelled_at.respond_to?(:iso8601) &&
                   acknowledgement.raw_response.is_a?(Hash)
              raise InvalidPayload, "IRP adapter returned invalid cancellation evidence"
            end
            acknowledgement
          end

          def validate_irn_status!(status)
            unless status.is_a?(IrnStatus) && status.irn.to_s.match?(/\A[0-9a-fA-F]{64}\z/) &&
                   %w[active cancelled].include?(status.status) && status.raw_response.is_a?(Hash)
              raise InvalidPayload, "IRP adapter returned an invalid IRN status"
            end
            if status.status == "cancelled" && !status.cancelled_at.respond_to?(:iso8601)
              raise InvalidPayload, "cancelled IRN status is missing its cancellation time"
            end
            status
          end
        end
      end
    end
  end
end
