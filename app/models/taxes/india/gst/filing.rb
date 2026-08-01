# frozen_string_literal: true

require "digest"

module Taxes
  module India
    module Gst
      # Builds deterministic GSTN Save-API payloads for the return surfaces Folio supports.
      # It does not submit, authenticate, offset liability, or claim unreconciled ITC.
      module Filing
        NotReady = Class.new(ArgumentError)
        InvalidPayload = Class.new(ArgumentError)

        SCHEMAS = {
          "GSTR1" => {
            version: "v5.0",
            status: "FINAL",
            published_on: Date.new(2026, 2, 23),
            sha256: "dbc6a2131a50d956ddf62df07204438b208820507e4b0cdca67ea8892b2a273a"
          },
          "GSTR3B" => {
            version: "v7.1",
            status: "DRAFT",
            published_on: Date.new(2026, 3, 23),
            sha256: "043917ea6fcbe34e97e851fde6cfe9a472aaefb2be503e9438973b16e67480ae"
          },
          "CMP08" => {
            version: "v1.2",
            status: "DRAFT",
            published_on: Date.new(2026, 4, 28),
            sha256: "0cf41f12ed533c2d93e5ed123fa504628aff04624c09ce08826024e650bb4810"
          }
        }.freeze
        MAX_GSTR1_BYTES = 5.megabytes

        Result = Data.define(
          :form, :schema_version, :schema_status, :schema_sha256,
          :payload, :payload_sha256, :crosscheck
        ) do
          def as_json(*)
            {
              form: form,
              schema_version: schema_version,
              schema_status: schema_status,
              schema_sha256: schema_sha256,
              payload_sha256: payload_sha256,
              crosscheck: crosscheck,
              payload: payload
            }
          end
        end

        module_function

        def gstr1(tenant_id:, tax_registration_id:, from_date:, to_date:)
          Gstr1.call(
            tenant_id: tenant_id,
            tax_registration_id: tax_registration_id,
            from_date: from_date,
            to_date: to_date
          )
        end

        def gstr3b(tenant_id:, tax_registration_id:, from_date:, to_date:, reviewed_itc:)
          Gstr3b.call(
            tenant_id: tenant_id,
            tax_registration_id: tax_registration_id,
            from_date: from_date,
            to_date: to_date,
            reviewed_itc: reviewed_itc
          )
        end

        def cmp08(gstin:, from_date:, to_date:, composition_type:,
                  reviewed_turnover_minor:, composition_rate_basis_points:)
          Cmp08.call(
            gstin: gstin,
            from_date: from_date,
            to_date: to_date,
            composition_type: composition_type,
            reviewed_turnover_minor: reviewed_turnover_minor,
            composition_rate_basis_points: composition_rate_basis_points
          )
        end

        def result(form:, payload:, crosscheck:)
          schema = SCHEMAS.fetch(form)
          Validator.validate!(form: form, payload: payload)
          canonical = Folio::KhataHash.canonical_payload(payload)
          if form == "GSTR1" && canonical.bytesize > MAX_GSTR1_BYTES
            raise NotReady, "GSTR-1 payload exceeds the GST portal 5 MB upload limit"
          end

          Result.new(
            form: form,
            schema_version: schema.fetch(:version),
            schema_status: schema.fetch(:status),
            schema_sha256: schema.fetch(:sha256),
            payload: deep_freeze(payload),
            payload_sha256: Digest::SHA256.hexdigest(canonical),
            crosscheck: deep_freeze(crosscheck)
          )
        end

        def deep_freeze(value)
          case value
          when Hash
            value.each { |key, child| key.freeze; deep_freeze(child) }
          when Array
            value.each { |child| deep_freeze(child) }
          end
          value.freeze
        end

        def regular_period!(from_date, to_date)
          unless from_date.is_a?(Date) && to_date.is_a?(Date) &&
                 from_date == from_date.beginning_of_month && to_date == from_date.end_of_month
            raise NotReady, "GSTR-1/GSTR-3B export currently requires one complete calendar month"
          end
          to_date
        end

        def composition_quarter!(from_date, to_date)
          valid_start_months = [ 4, 7, 10, 1 ]
          unless from_date.is_a?(Date) && to_date.is_a?(Date) &&
                 valid_start_months.include?(from_date.month) && from_date.day == 1 &&
                 to_date == (from_date + 3.months - 1.day)
            raise NotReady, "CMP-08 export requires a complete GST quarter"
          end
          to_date
        end

        def return_period(date) = date.strftime("%m%Y")
        def gst_date(date) = date.strftime("%d-%m-%Y")

        def rupees(minor)
          value = Integer(minor)
          value % 100 == 0 ? value / 100 : (value / 100.0).round(2)
        rescue ArgumentError, TypeError
          raise InvalidPayload, "minor-unit amount must be an integer"
        end

        def non_negative_minor!(value, label)
          parsed = Integer(value)
          raise NotReady, "#{label} must be non-negative" if parsed.negative?

          parsed
        rescue ArgumentError, TypeError
          raise NotReady, "#{label} must be an integer minor-unit amount"
        end
      end
    end
  end
end
