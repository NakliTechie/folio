# frozen_string_literal: true

module Posting
  module Rules
    # Debits governed expense and input-GST accounts and credits a vendor open payable.
    # When TDS applies, the vendor is credited net and TDS Payable is credited at invoice
    # posting — the statutory credit event, ordinarily earlier than settlement.
    # Reversals reuse the frozen bill snapshots and negate the same accounts.
    class PurchaseBill
      INPUT_TAX_ACCOUNT_CODE = "1210"
      PAYABLE_ACCOUNT_CODE = "2000"
      TDS_PAYABLE_ACCOUNT_CODE = "2110"

      class << self
        def validate_document!(document)
          lines = document.document_lines.to_a
          raise Documents::InvalidDocument, "a purchase bill needs at least one non-zero line" if lines.empty?
          required_header = %i[
            party_id tax_registration_id place_of_supply_state_code due_date currency minor_unit_exponent
            subtotal_minor tax_minor total_minor party_snapshot tax_registration_snapshot tax_breakdown
            place_of_supply_evidence
          ]
          missing = required_header.select { |attribute| document.public_send(attribute).blank? }
          raise Documents::InvalidDocument, "purchase bill is missing: #{missing.join(", ")}" if missing.any?
          if document.reverses_document_id.nil? && document.external_reference.blank?
            raise Documents::InvalidDocument, "purchase bill supplier invoice number is missing"
          end
          raise Documents::InvalidDocument, "purchase bill must be B2B" unless document.supply_type == "B2B"
          unless document.party_snapshot["id"].to_i == document.party_id &&
                 document.tax_registration_snapshot["id"].to_i == document.tax_registration_id
            raise Documents::InvalidDocument, "purchase bill master snapshots do not match their identities"
          end
          vendor_fields = %w[name addressLine1 city postalCode stateCode countryCode gstin gstinStateCode]
          buyer_fields = %w[legalName addressLine1 city postalCode stateCode countryCode identifier]
          if vendor_fields.any? { |field| document.party_snapshot[field].blank? } ||
             buyer_fields.any? { |field| document.tax_registration_snapshot[field].blank? }
            raise Documents::InvalidDocument, "purchase bill statutory snapshots are incomplete"
          end
          Taxes::India::PlaceOfSupplyEvidence.validate!(document)

          validate_lines!(document, lines)
          validate_tds_snapshot!(document)
        end

        def entry_lines(document)
          validate_document!(document)
          ledger = Ledger.find_by!(tenant_id: document.tenant_id, code: "PRIMARY")
          reversal = document.reverses_document_id.present?
          direction = reversal ? -1 : 1
          negative = reversal ? { is_negative_posting: true } : {}
          amount = ->(value) { transaction_amount(document, direction * value) }
          line_no = 0

          vendor_line = {
            line_no: line_no += 1,
            account_code: PAYABLE_ACCOUNT_CODE,
            ledger_id: ledger.id,
            entity_id: document.entity_id,
            office_id: document.office_id,
            party_id: document.party_id,
            party_role: "vendor",
            open_item: !reversal,
            item_class: "normal",
            assignment: "PB:#{document.reverses_document_id || document.id}",
            baseline_date: document.document_date,
            due_date: document.due_date,
            extra: {
              "partySnapshot" => document.party_snapshot,
              "placeOfSupplyEvidence" => document.place_of_supply_evidence,
              "supplierInvoiceNumber" => document.external_reference
            }.compact,
            amounts: [ amount.call(-(document.total_minor - document.tds_minor)) ]
          }.merge(negative)

          expense_lines = document.document_lines.map do |bill_line|
            {
              line_no: line_no += 1,
              account_code: bill_line.account_code,
              ledger_id: ledger.id,
              entity_id: document.entity_id,
              office_id: document.office_id,
              tax_registration_id: document.tax_registration_id,
              item_id: bill_line.item_id,
              quantity: bill_line.quantity,
              uom: bill_line.item_snapshot.fetch("unitOfMeasure"),
              hsn_sac_code: bill_line.hsn_sac_code,
              tax_rate_basis_points: bill_line.tax_rate_basis_points,
              taxable_amount_minor: bill_line.taxable_minor,
              extra: { "itemSnapshot" => bill_line.item_snapshot },
              amounts: [ amount.call(bill_line.taxable_minor) ]
            }.merge(negative)
          end

          tax_lines = document.document_lines.flat_map do |bill_line|
            bill_line.tax_components.sort.filter_map do |component, component_amount|
              next if component_amount.to_i.zero?

              {
                line_no: line_no += 1,
                account_code: INPUT_TAX_ACCOUNT_CODE,
                ledger_id: ledger.id,
                entity_id: document.entity_id,
                office_id: document.office_id,
                tax_registration_id: document.tax_registration_id,
                item_id: bill_line.item_id,
                hsn_sac_code: bill_line.hsn_sac_code,
                tax_component: component,
                tax_rate_basis_points: component_rate(bill_line, component),
                taxable_amount_minor: bill_line.taxable_minor,
                amounts: [ amount.call(Integer(component_amount)) ]
              }.merge(negative)
            end
          end

          tds_line = if document.tds_minor.positive?
            {
              line_no: line_no += 1,
              account_code: TDS_PAYABLE_ACCOUNT_CODE,
              ledger_id: ledger.id,
              entity_id: document.entity_id,
              office_id: document.office_id,
              amounts: [ amount.call(-document.tds_minor) ],
              extra: {
                "tdsSection" => document.tds_section,
                "statutoryReference" => document.tds_statutory_reference,
                "baseBasis" => document.tds_base_basis,
                "triggerEvent" => document.tds_trigger_event
              }
            }.merge(negative)
          end

          [ vendor_line, *expense_lines, *tax_lines, *[ tds_line ].compact ]
        end

        def after_post!(document:, entry:, actor:)
          return unless document.tds_minor.positive?

          original = if document.reverses_document_id
            TdsDeduction.find_by!(
              tenant_id: document.tenant_id,
              source_document_id: document.reverses_document_id,
              kind: "deduction"
            )
          end
          TdsDeduction.create!(
            tenant_id: document.tenant_id,
            party_id: document.party_id,
            section: document.tds_section,
            statutory_reference: document.tds_statutory_reference,
            rate_basis_points: document.tds_rate_basis_points,
            gross_minor: document.total_minor,
            gst_minor: document.tax_minor,
            taxable_minor: document.tds_taxable_minor,
            deductible_base_minor: document.tds_deductible_base_minor,
            tds_minor: document.tds_minor,
            base_basis: document.tds_base_basis,
            trigger_event: document.tds_trigger_event,
            kind: original ? "reversal" : "deduction",
            reverses_tds_deduction_id: original&.id,
            deduction_date: document.document_date,
            deductee_pan: PurchaseBills::TdsAssessment.pan_from_gstin(
              document.party_snapshot.fetch("gstin")
            ),
            deductee_name_snapshot: document.party_snapshot.fetch("name"),
            source_document_id: document.id,
            entry_id: entry.id,
            fiscal_year: document.fiscal_year,
            quarter: TdsDeduction.india_quarter(document.document_date)
          )
        end

        private

        def validate_tds_snapshot!(document)
          if document.reverses_document_id
            original = Document.find_by!(tenant_id: document.tenant_id, id: document.reverses_document_id)
            altered = PurchaseBills::TdsAssessment::SNAPSHOT_ATTRIBUTES.any? do |attribute|
              document.public_send(attribute) != original.public_send(attribute)
            end
            raise Documents::InvalidDocument, "purchase bill TDS reversal snapshot was altered" if altered
            return
          end

          unless PurchaseBills::TdsAssessment.matches_frozen?(document)
            raise Documents::InvalidDocument,
              "purchase bill TDS assessment is stale or was altered; discard and rebuild the draft"
          end
        rescue PurchaseBills::InvalidBill => e
          raise Documents::InvalidDocument, e.message
        end

        def validate_lines!(document, lines)
          subtotal = 0
          tax_total = 0
          breakdown = Hash.new(0)
          sign = document.reverses_document_id.present? ? -1 : 1
          lines.each do |line|
            unless line.item_id && line.quantity && line.unit_price_minor && line.taxable_minor &&
                   line.hsn_sac_code && line.item_snapshot.present? && line.tax_components.is_a?(Hash)
              raise Documents::InvalidDocument, "purchase bill line #{line.line_no} is incomplete"
            end
            unless line.item_snapshot["id"].to_i == line.item_id &&
                   expected_line_account(document, line) == line.account_code &&
                   line.item_snapshot["hsnSacCode"] == line.hsn_sac_code &&
                   line.item_snapshot["taxRateBasisPoints"].to_i == line.tax_rate_basis_points &&
                   line.item_snapshot["cessRateBasisPoints"].to_i == line.cess_rate_basis_points
              raise Documents::InvalidDocument, "purchase bill line #{line.line_no} snapshot was altered"
            end
            expected_taxable = (line.quantity * line.unit_price_minor).round(0, BigDecimal::ROUND_HALF_UP).to_i
            unless line.taxable_minor == expected_taxable && line.currency == document.currency &&
                   line.minor_unit_exponent == document.minor_unit_exponent
              raise Documents::InvalidDocument, "purchase bill line #{line.line_no} price or currency was altered"
            end
            unless line.amount_minor == sign * line.taxable_minor
              raise Documents::InvalidDocument, "purchase bill line #{line.line_no} amount was altered"
            end

            calculated = Taxes::India::Adapter.calculate(
              taxable_minor: line.taxable_minor,
              rate_basis_points: line.tax_rate_basis_points,
              cess_rate_basis_points: line.cess_rate_basis_points,
              supplier_state_code: document.party_snapshot.fetch("gstinStateCode"),
              place_of_supply_state_code: document.place_of_supply_state_code
            )
            expected = calculated.components.transform_keys(&:to_s)
            unless line.tax_components.transform_values(&:to_i) == expected
              raise Documents::InvalidDocument, "purchase bill line #{line.line_no} tax was altered"
            end

            subtotal += line.taxable_minor
            expected.each { |component, value| breakdown[component] += value }
            tax_total += expected.values.sum
          end
          unless document.subtotal_minor == subtotal && document.tax_minor == tax_total &&
                 document.total_minor == subtotal + tax_total &&
                 document.tax_breakdown.transform_values(&:to_i) == breakdown
            raise Documents::InvalidDocument, "purchase bill totals do not match its frozen lines"
          end
        end

        def expected_line_account(document, line)
          return line.item_snapshot["expenseAccountCode"] unless line.purchase_order_line_id

          match = procurement_match_for(document, line)
          unless match && match.purchase_order_id == document.purchase_order_id &&
              match.purchase_order_line_id == line.purchase_order_line_id
            raise Documents::InvalidDocument,
              "purchase bill line #{line.line_no} is missing its procurement-match evidence"
          end
          match.purchase_order_line.item_type == "good" ? "2050" : line.item_snapshot["expenseAccountCode"]
        end

        def procurement_match_for(document, line)
          return document.procurement_matches.find_by(document_line_id: line.id) unless document.reverses_document_id

          original_line = DocumentLine.find_by(
            document_id: document.reverses_document_id, line_no: line.line_no,
            purchase_order_line_id: line.purchase_order_line_id
          )
          original_line&.procurement_match
        end

        def transaction_amount(document, amount_minor)
          {
            slot_role: "transaction", currency: document.currency,
            minor_unit_exponent: document.minor_unit_exponent, amount_minor: amount_minor
          }
        end

        def component_rate(bill_line, component)
          return bill_line.cess_rate_basis_points if component == "cess"
          return bill_line.tax_rate_basis_points if component == "igst"

          unless bill_line.tax_rate_basis_points.even?
            raise Documents::InvalidDocument,
              "purchase bill line #{bill_line.line_no} GST rate cannot be split exactly"
          end

          bill_line.tax_rate_basis_points / 2
        end
      end
    end
  end
end
