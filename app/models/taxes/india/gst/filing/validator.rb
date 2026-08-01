# frozen_string_literal: true

module Taxes
  module India
    module Gst
      module Filing
        # Validates Folio's intentionally narrow supported payload profile against the field
        # constraints in the published GSTN Save schemas named in Filing::SCHEMAS.
        module Validator
          INVOICE_NUMBER = /\A(?=.{1,16}\z)[\/\-0]*[a-zA-Z0-9\/\-]*[a-zA-Z1-9]+[a-zA-Z0-9\/\-]*\z/
          PERIOD = /\A(0[1-9]|1[0-2])((19|20)\d\d)\z/
          GST_DATE = /\A\d{2}-\d{2}-\d{4}\z/
          COMPONENT_KEYS = %w[iamt camt samt csamt].freeze

          module_function

          def validate!(form:, payload:)
            hash!(payload, "payload")
            gstin!(payload.fetch("gstin"))
            case form
            when "GSTR1" then gstr1!(payload)
            when "GSTR3B" then gstr3b!(payload)
            when "CMP08" then cmp08!(payload)
            else raise InvalidPayload, "unsupported GST filing form #{form}"
            end
            true
          rescue KeyError => e
            raise InvalidPayload, "missing required GSTN field #{e.key}"
          end

          def gstr1!(payload)
            period!(payload.fetch("fp"))
            Array(payload["b2b"]).each do |recipient|
              gstin!(recipient.fetch("ctin"))
              non_empty_array!(recipient.fetch("inv"), "b2b invoices").each { |invoice| invoice!(invoice) }
            end
            Array(payload["cdnr"]).each do |recipient|
              gstin!(recipient.fetch("ctin"))
              non_empty_array!(recipient.fetch("nt"), "registered notes").each { |note| note!(note) }
            end
            hsn!(payload.fetch("hsn")) if payload.key?("hsn")
            doc_issue!(payload.fetch("doc_issue")) if payload.key?("doc_issue")
          end

          def invoice!(invoice)
            invoice_number!(invoice.fetch("inum"))
            date!(invoice.fetch("idt"))
            amount!(invoice.fetch("val"), "invoice value")
            state_code!(invoice.fetch("pos"))
            enum!(invoice.fetch("rchrg"), %w[Y N], "reverse charge")
            enum!(invoice.fetch("inv_typ"), %w[R DE SEWP SEWOP CBW], "invoice type")
            items!(invoice.fetch("itms"))
          end

          def note!(note)
            invoice_number!(note.fetch("nt_num"))
            date!(note.fetch("nt_dt"))
            amount!(note.fetch("val"), "note value")
            state_code!(note.fetch("pos"))
            enum!(note.fetch("ntty"), %w[C D R], "note type")
            enum!(note.fetch("rchrg"), %w[Y N], "reverse charge")
            enum!(note.fetch("inv_typ"), %w[R DE SEWP SEWOP CBW], "invoice type")
            items!(note.fetch("itms"))
          end

          def items!(items)
            non_empty_array!(items, "invoice items").each_with_index do |item, index|
              raise InvalidPayload, "item number must be positive" unless item.fetch("num").to_i.positive?
              details = hash!(item.fetch("itm_det"), "item details")
              amount!(details.fetch("txval"), "taxable value")
              amount!(details.fetch("rt"), "tax rate")
              COMPONENT_KEYS.each { |key| amount!(details[key], key) if details.key?(key) }
              raise InvalidPayload, "item numbers must be sequential" unless item.fetch("num") == index + 1
            end
          end

          def hsn!(hsn)
            rows = non_empty_array!(hash!(hsn, "hsn").fetch("hsn_b2b"), "HSN B2B rows")
            rows.each_with_index do |row, index|
              unless row.fetch("hsn_sc").match?(/\A\d{2,8}\z/) && row.fetch("uqc").match?(/\A[a-zA-Z]+\z/)
                raise InvalidPayload, "HSN/SAC and UQC must match the GSTN schema"
              end
              raise InvalidPayload, "HSN row numbers must be sequential" unless row.fetch("num") == index + 1
              amount!(row.fetch("qty"), "HSN quantity", signed: true)
              amount!(row.fetch("txval"), "HSN taxable value", signed: true)
              amount!(row.fetch("rt"), "HSN rate")
              COMPONENT_KEYS.each { |key| amount!(row[key], key, signed: true) if row.key?(key) }
            end
          end

          def doc_issue!(doc_issue)
            Array(hash!(doc_issue, "document issue").fetch("doc_det")).each do |type|
              raise InvalidPayload, "document nature code must be 1..12" unless (1..12).cover?(type.fetch("doc_num"))
              Array(type.fetch("docs")).each do |series|
                invoice_number!(series.fetch("from"))
                invoice_number!(series.fetch("to"))
                raise InvalidPayload, "num must be a positive integer" unless series.fetch("num").is_a?(Integer) && series.fetch("num").positive?
                %w[totnum net_issue cancel].each do |key|
                  raise InvalidPayload, "#{key} must be a non-negative integer" unless series.fetch(key).is_a?(Integer) && series.fetch(key) >= 0
                end
              end
            end
          end

          def gstr3b!(payload)
            period!(payload.fetch("ret_period"))
            supply = hash!(payload.fetch("sup_details"), "supply details")
            %w[osup_det isup_rev].each { |key| amounts!(supply.fetch(key), taxable_key: "txval") }
            zero = supply.fetch("osup_zero")
            %w[txval iamt csamt].each { |key| amount!(zero.fetch(key), key, signed: true) }
            %w[osup_nil_exmp osup_nongst].each do |key|
              amount!(supply.fetch(key).fetch("txval"), key, signed: true)
            end
            itc = hash!(payload.fetch("itc_elg"), "eligible ITC")
            Array(itc.fetch("itc_avl")).each { |row| tax_components!(row) }
            Array(itc.fetch("itc_rev")).each { |row| tax_components!(row) }
            tax_components!(itc.fetch("itc_net"), signed: true)
            Array(itc.fetch("itc_inelg")).each { |row| tax_components!(row) }
          end

          def cmp08!(payload)
            period!(payload.fetch("ret_period"))
            enum!(payload.fetch("isnil"), %w[Y N], "nil return flag")
            return if payload.fetch("isnil") == "Y"

            table = hash!(payload.fetch("table3"), "CMP-08 table 3")
            %w[out_sup out_ser out_ecom].each do |key|
              row = table.fetch(key)
              amount!(row.fetch("tax_val"), key, signed: true)
              amount!(row.fetch("camt"), key, signed: true)
              amount!(row.fetch("samt"), key, signed: true)
            end
            %w[tax_pay in_sup].each { |key| amounts!(table.fetch(key), taxable_key: "tax_val") }
            tax_components!(table.fetch("intr_pay"))
          end

          def amounts!(row, taxable_key:)
            amount!(row.fetch(taxable_key), taxable_key, signed: true)
            tax_components!(row, signed: true)
          end

          def tax_components!(row, signed: false)
            COMPONENT_KEYS.each { |key| amount!(row.fetch(key), key, signed: signed) }
          end

          def gstin!(value)
            raise InvalidPayload, "GSTIN is invalid" unless Taxes::India::Gstin.valid?(value)
          end

          def period!(value)
            raise InvalidPayload, "return period must be MMYYYY" unless value.to_s.match?(PERIOD)
          end

          def invoice_number!(value)
            raise InvalidPayload, "document number is not GSTN-compatible" unless value.to_s.match?(INVOICE_NUMBER)
          end

          def state_code!(value)
            raise InvalidPayload, "place of supply is invalid" unless Taxes::India::StateCodes.valid?(value)
          end

          def date!(value)
            raise InvalidPayload, "document date must be DD-MM-YYYY" unless value.to_s.match?(GST_DATE)
            Date.strptime(value, "%d-%m-%Y")
          rescue Date::Error
            raise InvalidPayload, "document date is invalid"
          end

          def amount!(value, label, signed: false)
            unless value.is_a?(Numeric) && value.finite? && value.round(2) == value && (signed || value >= 0)
              raise InvalidPayload, "#{label} must be a #{signed ? '' : 'non-negative '}two-decimal number"
            end
          end

          def enum!(value, allowed, label)
            raise InvalidPayload, "#{label} is invalid" unless allowed.include?(value)
          end

          def hash!(value, label)
            raise InvalidPayload, "#{label} must be an object" unless value.is_a?(Hash)

            value
          end

          def non_empty_array!(value, label)
            raise InvalidPayload, "#{label} cannot be empty" unless value.is_a?(Array) && value.any?

            value
          end
        end
      end
    end
  end
end
