# frozen_string_literal: true

require "digest"

module Taxes
  module India
    module Gst
      # India FORM GST INV-01 v1.1 request and IRP provider boundary. Folio prepares and
      # validates requests offline; a live provider must be explicitly injected and configured.
      module EInvoice
        SCHEMA_VERSION = "1.1"
        SCHEMA_REFERENCE = "FORM GST INV-01 v1.1 (Notification 60/2020-Central Tax)"
        DOCUMENT_TYPES = { "SI" => "INV", "CN" => "CRN" }.freeze

        NotReady = Class.new(ArgumentError)
        InvalidPayload = Class.new(ArgumentError)

        module_function

        def build(document)
          Builder.call(document)
        end

        def canonical_digest(payload)
          Digest::SHA256.hexdigest(Folio::KhataHash.canonical_payload(payload))
        end

        def rupees(minor)
          value = Integer(minor)
          value % 100 == 0 ? value / 100 : (value / 100.0).round(2)
        rescue ArgumentError, TypeError
          raise InvalidPayload, "minor-unit amount must be an integer"
        end

        def percentage(basis_points)
          value = Integer(basis_points)
          value % 100 == 0 ? value / 100 : (value / 100.0).round(2)
        end
      end
    end
  end
end
