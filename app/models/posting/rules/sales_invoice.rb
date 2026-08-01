# frozen_string_literal: true

module Posting
  module Rules
    # Expands frozen invoice lines into one customer/open-item debit, revenue credits, and typed
    # GST component credits. A reversal negates those same-account lines and marks them negative.
    class SalesInvoice
      TAX_ACCOUNT_CODE = "2100"
      RECEIVABLE_ACCOUNT_CODE = "1200"

      class << self
        def validate_document!(document)
          lines = document.document_lines.to_a
          raise Documents::InvalidDocument, "a sales invoice needs at least one non-zero line" if lines.empty?
          required_header = %i[
            party_id tax_registration_id place_of_supply_state_code due_date currency minor_unit_exponent
            subtotal_minor tax_minor total_minor party_snapshot tax_registration_snapshot tax_breakdown
            place_of_supply_evidence
          ]
          missing = required_header.select { |attribute| document.public_send(attribute).blank? }
          raise Documents::InvalidDocument, "sales invoice is missing: #{missing.join(", ")}" if missing.any?
          raise Documents::InvalidDocument, "sales invoice must be B2B" unless document.supply_type == "B2B"
          unless document.party_snapshot["id"].to_i == document.party_id &&
                 document.tax_registration_snapshot["id"].to_i == document.tax_registration_id
            raise Documents::InvalidDocument, "sales invoice master snapshots do not match their identities"
          end
          seller_fields = %w[legalName addressLine1 city postalCode stateCode countryCode]
          if seller_fields.any? { |field| document.tax_registration_snapshot[field].blank? }
            raise Documents::InvalidDocument, "sales invoice seller snapshot is incomplete"
          end
          Taxes::India::PlaceOfSupplyEvidence.validate!(document)

          validate_lines!(document, lines)
        end

        def entry_lines(document)
          validate_document!(document)
          ledger = Ledger.find_by!(tenant_id: document.tenant_id, code: "PRIMARY")
          reversal = document.reverses_document_id.present?
          direction = reversal ? -1 : 1
          negative = reversal ? { is_negative_posting: true } : {}
          amount = ->(value) { transaction_amount(document, direction * value) }
          line_no = 0

          customer_line = {
            line_no: line_no += 1,
            account_code: RECEIVABLE_ACCOUNT_CODE,
            ledger_id: ledger.id,
            entity_id: document.entity_id,
            office_id: document.office_id,
            party_id: document.party_id,
            party_role: "customer",
            open_item: !reversal,
            item_class: "normal",
            assignment: "SI:#{document.reverses_document_id || document.id}",
            baseline_date: document.document_date,
            due_date: document.due_date,
            extra: {
              "partySnapshot" => document.party_snapshot,
              "placeOfSupplyEvidence" => document.place_of_supply_evidence
            },
            amounts: [ amount.call(document.total_minor) ]
          }.merge(negative)

          revenue_lines = document.document_lines.map do |invoice_line|
            {
              line_no: line_no += 1,
              account_code: invoice_line.account_code,
              ledger_id: ledger.id,
              entity_id: document.entity_id,
              office_id: document.office_id,
              tax_registration_id: document.tax_registration_id,
              item_id: invoice_line.item_id,
              quantity: invoice_line.quantity,
              uom: invoice_line.item_snapshot.fetch("unitOfMeasure"),
              hsn_sac_code: invoice_line.hsn_sac_code,
              tax_rate_basis_points: invoice_line.tax_rate_basis_points,
              taxable_amount_minor: invoice_line.taxable_minor,
              extra: { "itemSnapshot" => invoice_line.item_snapshot },
              amounts: [ amount.call(-invoice_line.taxable_minor) ]
            }.merge(negative)
          end

          tax_lines = document.document_lines.flat_map do |invoice_line|
            invoice_line.tax_components.sort.filter_map do |component, component_amount|
              next if component_amount.to_i.zero?

              {
                line_no: line_no += 1,
                account_code: TAX_ACCOUNT_CODE,
                ledger_id: ledger.id,
                entity_id: document.entity_id,
                office_id: document.office_id,
                tax_registration_id: document.tax_registration_id,
                item_id: invoice_line.item_id,
                hsn_sac_code: invoice_line.hsn_sac_code,
                tax_component: component,
                tax_rate_basis_points: component_rate(invoice_line, component),
                taxable_amount_minor: invoice_line.taxable_minor,
                amounts: [ amount.call(-Integer(component_amount)) ]
              }.merge(negative)
            end
          end

          [ customer_line, *revenue_lines, *tax_lines ]
        end

        private

        def validate_lines!(document, lines)
          subtotal = 0
          tax_total = 0
          breakdown = Hash.new(0)
          sign = document.reverses_document_id.present? ? 1 : -1
          lines.each do |line|
            unless line.item_id && line.quantity && line.unit_price_minor && line.taxable_minor &&
                   line.hsn_sac_code && line.item_snapshot.present? && line.tax_components.is_a?(Hash)
              raise Documents::InvalidDocument, "sales invoice line #{line.line_no} is incomplete"
            end
            unless line.item_snapshot["id"].to_i == line.item_id &&
                   line.item_snapshot["incomeAccountCode"] == line.account_code &&
                   line.item_snapshot["hsnSacCode"] == line.hsn_sac_code &&
                   line.item_snapshot["taxRateBasisPoints"].to_i == line.tax_rate_basis_points &&
                   line.item_snapshot["cessRateBasisPoints"].to_i == line.cess_rate_basis_points
              raise Documents::InvalidDocument, "sales invoice line #{line.line_no} snapshot was altered"
            end
            expected_taxable = (line.quantity * line.unit_price_minor).round(0, BigDecimal::ROUND_HALF_UP).to_i
            unless line.taxable_minor == expected_taxable && line.currency == document.currency &&
                   line.minor_unit_exponent == document.minor_unit_exponent
              raise Documents::InvalidDocument, "sales invoice line #{line.line_no} price or currency was altered"
            end
            unless line.amount_minor == sign * line.taxable_minor
              raise Documents::InvalidDocument, "sales invoice line #{line.line_no} amount was altered"
            end

            calculated = Taxes::India::Adapter.calculate(
              taxable_minor: line.taxable_minor,
              rate_basis_points: line.tax_rate_basis_points,
              cess_rate_basis_points: line.cess_rate_basis_points,
              supplier_state_code: document.tax_registration_snapshot.fetch("stateCode"),
              place_of_supply_state_code: document.place_of_supply_state_code
            )
            expected = calculated.components.transform_keys(&:to_s)
            unless line.tax_components.transform_values(&:to_i) == expected
              raise Documents::InvalidDocument, "sales invoice line #{line.line_no} tax was altered"
            end

            subtotal += line.taxable_minor
            expected.each { |component, value| breakdown[component] += value }
            tax_total += expected.values.sum
          end
          unless document.subtotal_minor == subtotal && document.tax_minor == tax_total &&
                 document.total_minor == subtotal + tax_total &&
                 document.tax_breakdown.transform_values(&:to_i) == breakdown
            raise Documents::InvalidDocument, "sales invoice totals do not match its frozen lines"
          end
        end

        def transaction_amount(document, amount_minor)
          {
            slot_role: "transaction", currency: document.currency,
            minor_unit_exponent: document.minor_unit_exponent, amount_minor: amount_minor
          }
        end

        def component_rate(invoice_line, component)
          return invoice_line.cess_rate_basis_points if component == "cess"
          return invoice_line.tax_rate_basis_points if component == "igst"

          unless invoice_line.tax_rate_basis_points.even?
            raise Documents::InvalidDocument,
              "sales invoice line #{invoice_line.line_no} GST rate cannot be split exactly"
          end

          invoice_line.tax_rate_basis_points / 2
        end
      end
    end
  end
end
