# frozen_string_literal: true

require "digest"

module Taxes
  module India
    module Gst
      # FORM GST EWB-01 transport details carried inside INV-01 for IRN-enabled B2B invoices.
      module EwayBill
        SCHEMA_VERSION = "INV-01-EWB-1.1"
        SCHEMA_REFERENCE = "FORM GST EWB-01 through INV-01 v1.1 EwbDtls"
        MANDATORY_THRESHOLD_MINOR = 50_000 * 100
        MAX_DISTANCE_KM = 4_000
        MAX_ITEMS = 250
        MAX_DOCUMENT_AGE_DAYS = 180
        TRANSPORT_MODES = {
          "1" => "Road", "2" => "Rail", "3" => "Air", "4" => "Ship"
        }.freeze
        VEHICLE_TYPES = { "R" => "Regular", "O" => "Over-dimensional cargo" }.freeze

        NotReady = Class.new(ArgumentError)
        InvalidPayload = Class.new(ArgumentError)

        module_function

        def build(document, attributes)
          Builder.call(document, attributes)
        end

        def canonical_digest(payload)
          Digest::SHA256.hexdigest(Folio::KhataHash.canonical_payload(payload))
        end
      end
    end
  end
end
