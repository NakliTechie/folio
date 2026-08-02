# frozen_string_literal: true

module Taxes
  module India
    module Gst
      module EwayBill
        # Builds the narrow transport-details object accepted as INV-01 EwbDtls. Invoice, party,
        # item, value, and tax details remain sourced from the already frozen INV-01 payload.
        module Builder
          TRANSPORTER_ID = /\A[0-9A-Z]{15}\z/
          VEHICLE_NUMBER = /\A[A-Z0-9]{4,20}\z/

          module_function

          def call(document, attributes)
            validate_document!(document)
            mode = value(attributes, :transport_mode).to_s
            enum!(mode, TRANSPORT_MODES.keys, "transport mode")
            distance = integer!(value(attributes, :distance_km), "distance")
            unless distance.between?(0, MAX_DISTANCE_KM)
              raise InvalidPayload, "distance must be between 0 and #{MAX_DISTANCE_KM} km"
            end

            transporter_id = normalize_identifier(value(attributes, :transporter_id))
            if transporter_id.present? && !transporter_id.match?(TRANSPORTER_ID)
              raise InvalidPayload, "transporter ID must be a 15-character GSTIN or TRANSIN"
            end
            transporter_name = bounded(value(attributes, :transporter_name), "transporter name", 100)
            vehicle_number = normalize_vehicle(value(attributes, :vehicle_number))
            vehicle_type = value(attributes, :vehicle_type).to_s.upcase.presence || "R"
            enum!(vehicle_type, VEHICLE_TYPES.keys, "vehicle type")
            transport_document_number = bounded(
              value(attributes, :transport_document_number), "transport document number", 15
            )
            transport_document_date = transport_date(
              value(attributes, :transport_document_date), document.document_date
            )

            if mode == "1"
              raise InvalidPayload, "vehicle number is required for road transport" if vehicle_number.blank?
              unless vehicle_number.match?(VEHICLE_NUMBER)
                raise InvalidPayload, "vehicle number must use the portal's alphanumeric format"
              end
            elsif transport_document_number.blank? || transport_document_date.blank?
              raise InvalidPayload, "transport document number and date are required for rail, air, or ship"
            end

            {
              "TransId" => transporter_id,
              "TransName" => transporter_name,
              "Distance" => distance,
              "TransDocNo" => transport_document_number,
              "TransDocDt" => transport_document_date,
              "VehNo" => vehicle_number,
              "VehType" => vehicle_type,
              "TransMode" => mode
            }.compact_blank.freeze
          end

          def validate_document!(document)
            unless document.is_a?(Document) && document.doc_type == "SI" && document.posted?
              raise NotReady, "e-way bill preparation requires a posted sales invoice"
            end
            raise NotReady, "reversed invoices cannot generate an e-way bill" if document.state == "reversed"
            raise NotReady, "e-way bill preparation currently requires INR" unless document.currency == "INR"
            unless document.supply_type == "B2B" && document.statutory_printable?
              raise NotReady, "e-way bill preparation requires complete domestic B2B statutory snapshots"
            end
            if document.document_date < MAX_DOCUMENT_AGE_DAYS.days.ago.to_date
              raise NotReady, "the invoice is older than the portal's #{MAX_DOCUMENT_AGE_DAYS}-day generation window"
            end
            raise NotReady, "an e-way bill requires at least one goods line" unless document.contains_goods?
            if document.document_lines.size > MAX_ITEMS
              raise NotReady, "EWB-01 permits at most #{MAX_ITEMS} item lines"
            end
          end

          def transport_date(raw, document_date)
            return if raw.blank?

            date = raw.is_a?(Date) ? raw : Date.iso8601(raw.to_s)
            raise InvalidPayload, "transport document date cannot precede the invoice" if date < document_date
            raise InvalidPayload, "transport document date cannot be in the future" if date > Time.zone.today

            date.strftime("%d/%m/%Y")
          rescue Date::Error
            raise InvalidPayload, "transport document date must be a valid date"
          end

          def bounded(raw, label, maximum)
            result = raw.to_s.strip.presence
            raise InvalidPayload, "#{label} may be no more than #{maximum} characters" if result&.length.to_i > maximum

            result
          end

          def integer!(raw, label)
            Integer(raw.to_s, 10)
          rescue ArgumentError, TypeError
            raise InvalidPayload, "#{label} must be a whole number"
          end

          def enum!(value, allowed, label)
            raise InvalidPayload, "#{label} is invalid" unless allowed.include?(value)
          end

          def normalize_identifier(value) = value.to_s.upcase.gsub(/[^A-Z0-9]/, "").presence
          def normalize_vehicle(value) = value.to_s.upcase.gsub(/[^A-Z0-9]/, "").presence
          def value(attributes, key) = attributes[key] || attributes[key.to_s]
        end
      end
    end
  end
end
