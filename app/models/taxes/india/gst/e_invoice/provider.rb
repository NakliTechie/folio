# frozen_string_literal: true

require "digest"

module Taxes
  module India
    module Gst
      module EInvoice
        # Normalized provider boundary. Concrete GSP/IRP adapters translate their wire formats
        # into Acknowledgement or raise Rejection/TransportError. Tokens never cross this seam.
        module Provider
          MAX_RAW_RESPONSE_BYTES = 256.kilobytes
          MAX_SIGNED_ARTIFACT_BYTES = 1.megabyte
          MAX_ERROR_MESSAGE_BYTES = 2.kilobytes
          FORBIDDEN_EVIDENCE_KEYS = %w[
            password passwd authorization authtoken accesstoken refreshtoken
            apikey clientsecret sek appkey
          ].freeze
          DocumentIdentity = Data.define(
            :seller_gstin, :document_type, :document_number, :document_date
          )
          Acknowledgement = Data.define(
            :irn, :ack_number, :acknowledged_at, :signed_invoice, :signed_qr_code,
            :raw_response, :signature_status, :document_identity, :eway_bill
          )
          EwayBillEvidence = Data.define(:eway_bill_number, :generated_at, :valid_until)
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
            unless acknowledgement.document_identity.is_a?(DocumentIdentity)
              raise InvalidPayload, "IRP acknowledgement document identity is required"
            end
            validate_signed_artifact!(acknowledgement.signed_invoice, "signed invoice")
            validate_signed_artifact!(acknowledgement.signed_qr_code, "signed QR code")
            validate_raw_response!(acknowledgement.raw_response)
            validate_eway_bill_evidence!(acknowledgement)
            acknowledgement
          end

          def validate_eway_bill_evidence!(acknowledgement)
            evidence = acknowledgement.eway_bill
            return if evidence.nil?

            unless evidence.is_a?(EwayBillEvidence) &&
                   evidence.eway_bill_number.to_s.match?(/\A\d{12}\z/) &&
                   evidence.generated_at.respond_to?(:iso8601) &&
                   evidence.valid_until.respond_to?(:iso8601) &&
                   evidence.valid_until > evidence.generated_at
              raise InvalidPayload, "IRP adapter returned invalid e-way bill evidence"
            end
          end

          def bind_acknowledgement!(acknowledgement, payload)
            expected = document_identity(payload)
            actual = acknowledgement.document_identity
            unless actual && expected.members.all? do |field|
              actual.public_send(field).to_s == expected.public_send(field).to_s
            end
              raise InvalidPayload, "IRP acknowledgement names a different statutory document"
            end
            unless acknowledgement.irn.casecmp?(expected_irn(payload))
              raise InvalidPayload, "IRP acknowledgement IRN does not match the submitted document"
            end
            if payload.key?("EwbDtls") && acknowledgement.eway_bill.nil?
              raise InvalidPayload, "IRP acknowledgement omitted the requested e-way bill evidence"
            end
            if !payload.key?("EwbDtls") && acknowledgement.eway_bill
              raise InvalidPayload, "IRP acknowledgement returned an unrequested e-way bill"
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
            validate_raw_response!(acknowledgement.raw_response)
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
            validate_raw_response!(status.raw_response)
            status
          end

          def document_identity(payload)
            doc = payload.fetch("DocDtls")
            DocumentIdentity.new(
              seller_gstin: payload.dig("SellerDtls", "Gstin"),
              document_type: doc.fetch("Typ"),
              document_number: doc.fetch("No"),
              document_date: doc.fetch("Dt")
            )
          end

          # IRIS IRP publishes the preimage as supplier GSTIN + financial year + document
          # type + document number. The financial year is derived from the document date.
          def expected_irn(payload)
            identity = document_identity(payload)
            date = Date.strptime(identity.document_date, "%d/%m/%Y")
            start_year = date.month >= 4 ? date.year : date.year - 1
            financial_year = format("%<start>d-%<finish>02d", start: start_year, finish: (start_year + 1) % 100)
            Digest::SHA256.hexdigest(
              "#{identity.seller_gstin}#{financial_year}#{identity.document_type}#{identity.document_number}"
            )
          rescue Date::Error
            raise InvalidPayload, "submitted e-invoice document date is invalid"
          end

          def validate_raw_response!(response)
            unless response.is_a?(Hash)
              raise InvalidPayload, "IRP raw response must be retained as an object"
            end
            if Folio::KhataHash.canonical_payload(response).bytesize > MAX_RAW_RESPONSE_BYTES
              raise InvalidPayload, "IRP raw response exceeds the evidence size limit"
            end
            reject_secret_keys!(response)
            response
          end

          def validate_signed_artifact!(value, label)
            unless value.is_a?(String) && value.bytesize <= MAX_SIGNED_ARTIFACT_BYTES
              raise InvalidPayload, "IRP #{label} exceeds the evidence size limit"
            end
          end

          def safe_error_message(error)
            value = error.message.to_s
            if value.match?(/bearer|password|secret|api[ _-]?key|access[ _-]?token|refresh[ _-]?token/i)
              return "IRP provider error details were rejected by evidence policy"
            end
            value.byteslice(0, MAX_ERROR_MESSAGE_BYTES)
          end

          def safe_error_code(error)
            error.code.to_s.byteslice(0, 64).presence
          end

          def safe_error_response(error)
            response = error.raw_response
            return unless response.is_a?(Hash)

            validate_raw_response!(response)
          rescue InvalidPayload
            nil
          end

          def reject_secret_keys!(value)
            case value
            when Hash
              value.each do |key, child|
                normalized = key.to_s.downcase.gsub(/[^a-z0-9]/, "")
                if FORBIDDEN_EVIDENCE_KEYS.include?(normalized)
                  raise InvalidPayload, "IRP raw response contains a forbidden credential field"
                end
                reject_secret_keys!(child)
              end
            when Array
              value.each { |child| reject_secret_keys!(child) }
            end
          end
        end
      end
    end
  end
end
