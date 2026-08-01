# frozen_string_literal: true

module Taxes
  module India
    module Gst
      module EInvoice
        # Validates Folio's narrow domestic B2B INV-01 v1.1 profile before it crosses an
        # adapter boundary. Provider-side master/enablement checks remain authoritative.
        module Validator
          DOCUMENT_NUMBER = /\A(?![0\/-])[A-Z0-9\/-]{1,16}\z/
          UQC = /\A[A-Z]{3,8}\z/

          module_function

          def validate!(payload)
            object!(payload, "payload")
            exact!(payload.fetch("Version"), SCHEMA_VERSION, "schema version")
            transaction!(payload.fetch("TranDtls"))
            document!(payload.fetch("DocDtls"))
            party!(payload.fetch("SellerDtls"), "seller")
            party!(payload.fetch("BuyerDtls"), "buyer", buyer: true)
            items!(payload.fetch("ItemList"))
            totals!(payload.fetch("ValDtls"), payload.fetch("ItemList"))
            true
          rescue KeyError => e
            raise InvalidPayload, "missing required INV-01 field #{e.key}"
          end

          def transaction!(details)
            object!(details, "transaction details")
            exact!(details.fetch("TaxSch"), "GST", "tax scheme")
            exact!(details.fetch("SupTyp"), "B2B", "supply type")
            %w[RegRev IgstOnIntra].each { |key| enum!(details.fetch(key), %w[Y N], key) }
          end

          def document!(details)
            object!(details, "document details")
            enum!(details.fetch("Typ"), %w[INV CRN], "document type")
            unless details.fetch("No").to_s.match?(DOCUMENT_NUMBER)
              raise InvalidPayload, "document number must be uppercase INV-01 format and at most 16 characters"
            end
            date = details.fetch("Dt").to_s
            raise Date::Error unless date.match?(/\A\d{2}\/\d{2}\/\d{4}\z/)

            Date.strptime(date, "%d/%m/%Y")
          rescue Date::Error
            raise InvalidPayload, "document date must be DD/MM/YYYY"
          end

          def party!(details, label, buyer: false)
            object!(details, "#{label} details")
            gstin = details.fetch("Gstin")
            raise InvalidPayload, "#{label} GSTIN is invalid" unless Taxes::India::Gstin.valid?(gstin)

            string!(details.fetch("LglNm"), "#{label} legal name", max: 100)
            string!(details.fetch("Addr1"), "#{label} address", max: 100)
            string!(details.fetch("Loc"), "#{label} location", max: 50)
            pin = details.fetch("Pin")
            raise InvalidPayload, "#{label} pin code is invalid" unless pin.is_a?(Integer) && pin.between?(100_000, 999_999)
            state = details.fetch("Stcd")
            raise InvalidPayload, "#{label} state code is invalid" unless Taxes::India::StateCodes.valid?(state)
            if gstin.first(2) != state
              raise InvalidPayload, "#{label} GSTIN state does not match the address state"
            end
            return unless buyer

            pos = details.fetch("Pos")
            raise InvalidPayload, "buyer place of supply is invalid" unless Taxes::India::StateCodes.valid?(pos)
          end

          def items!(items)
            unless items.is_a?(Array) && items.any? && items.size <= 1_000
              raise InvalidPayload, "INV-01 requires 1..1,000 item lines"
            end
            items.each_with_index do |item, index|
              object!(item, "item")
              exact!(item.fetch("SlNo"), (index + 1).to_s, "item serial number")
              string!(item.fetch("PrdDesc"), "product description", max: 300)
              enum!(item.fetch("IsServc"), %w[Y N], "service flag")
              raise InvalidPayload, "HSN/SAC is invalid" unless item.fetch("HsnCd").to_s.match?(/\A\d{2,8}\z/)
              raise InvalidPayload, "unit code is invalid" unless item.fetch("Unit").to_s.match?(UQC)
              %w[Qty UnitPrice TotAmt AssAmt GstRt IgstAmt CgstAmt SgstAmt TotItemVal].each do |key|
                amount!(item.fetch(key), key)
              end
              %w[CesRt CesAmt].each { |key| amount!(item.fetch(key), key) if item.key?(key) }
              expected = item.fetch("AssAmt") + item.fetch("IgstAmt") + item.fetch("CgstAmt") +
                item.fetch("SgstAmt") + item.fetch("CesAmt", 0)
              unless close?(item.fetch("TotItemVal"), expected)
                raise InvalidPayload, "item total does not reconcile to taxable value and tax"
              end
            end
          end

          def totals!(totals, items)
            object!(totals, "value details")
            keys = %w[AssVal CgstVal SgstVal IgstVal CesVal TotInvVal]
            keys.each { |key| amount!(totals.fetch(key), key) }
            expected = totals.fetch("AssVal") + totals.fetch("CgstVal") + totals.fetch("SgstVal") +
              totals.fetch("IgstVal") + totals.fetch("CesVal")
            raise InvalidPayload, "invoice total does not reconcile" unless close?(totals.fetch("TotInvVal"), expected)
            raise InvalidPayload, "item totals do not reconcile to invoice total" unless close?(
              items.sum { |item| item.fetch("TotItemVal") }, totals.fetch("TotInvVal")
            )
          end

          def amount!(value, label)
            unless value.is_a?(Numeric) && value.finite? && value >= 0 && value.round(2) == value
              raise InvalidPayload, "#{label} must be a non-negative two-decimal number"
            end
          end

          def string!(value, label, max:)
            unless value.is_a?(String) && value.present? && value.length <= max
              raise InvalidPayload, "#{label} must be present and at most #{max} characters"
            end
          end

          def object!(value, label)
            raise InvalidPayload, "#{label} must be an object" unless value.is_a?(Hash)
          end

          def enum!(value, allowed, label)
            raise InvalidPayload, "#{label} is invalid" unless allowed.include?(value)
          end

          def exact!(value, expected, label)
            raise InvalidPayload, "#{label} must be #{expected}" unless value == expected
          end

          def close?(left, right)
            (left.to_d - right.to_d).abs <= 0.01.to_d
          end
        end
      end
    end
  end
end
