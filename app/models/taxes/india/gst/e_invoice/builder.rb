# frozen_string_literal: true

module Taxes
  module India
    module Gst
      module EInvoice
        # Builds Folio's governed domestic B2B profile of the notified INV-01 v1.1 schema.
        module Builder
          module_function

          def call(document)
            validate_document!(document)
            seller = document.tax_registration_snapshot
            buyer = document.party_snapshot
            payload = {
              "Version" => SCHEMA_VERSION,
              "TranDtls" => {
                "TaxSch" => "GST", "SupTyp" => document.supply_type,
                "RegRev" => "N", "IgstOnIntra" => "N"
              },
              "DocDtls" => {
                "Typ" => DOCUMENT_TYPES.fetch(document.doc_type),
                "No" => document.document_number,
                "Dt" => document.document_date.strftime("%d/%m/%Y")
              },
              "SellerDtls" => party_details(seller, seller: true),
              "BuyerDtls" => party_details(buyer, seller: false).merge(
                "Pos" => document.place_of_supply_state_code
              ),
              "ItemList" => document.document_lines.sort_by(&:line_no).map { |line| item(line) },
              "ValDtls" => value_details(document)
            }
            eway_bill = document.eway_bill_submission
            payload["EwbDtls"] = eway_bill.payload.deep_dup if eway_bill
            Validator.validate!(payload)
            deep_freeze(payload)
          end

          def validate_document!(document)
            unless document.is_a?(Document) && DOCUMENT_TYPES.key?(document.doc_type) && document.posted?
              raise NotReady, "e-invoice preparation requires a posted sales invoice or credit note"
            end
            raise NotReady, "reversed documents cannot be prepared for IRN" if document.state == "reversed"
            raise NotReady, "e-invoice preparation currently requires INR" unless document.currency == "INR"
            unless document.supply_type == "B2B" && document.statutory_printable?
              raise NotReady, "e-invoice preparation currently requires complete domestic B2B statutory snapshots"
            end
            if document.document_lines.size > 1_000
              raise NotReady, "INV-01 permits at most 1,000 item lines"
            end
            if document.eway_bill_required? && !document.eway_bill_submission
              raise NotReady,
                "goods consignments over INR 50,000 require e-way transport details before INV-01 preparation"
            end
          end

          def party_details(snapshot, seller:)
            result = {
              "Gstin" => snapshot.fetch(seller ? "identifier" : "gstin"),
              "LglNm" => snapshot.fetch(seller ? "legalName" : "name"),
              "Addr1" => snapshot.fetch("addressLine1"),
              "Loc" => snapshot.fetch("city"),
              "Pin" => Integer(snapshot.fetch("postalCode")),
              "Stcd" => snapshot.fetch("stateCode")
            }
            result["TrdNm"] = snapshot["officeName"] if seller && snapshot["officeName"].present?
            result["Addr2"] = snapshot["addressLine2"] if snapshot["addressLine2"].present?
            result["Ph"] = snapshot["phone"] unless seller || snapshot["phone"].blank?
            result["Em"] = snapshot["email"] unless seller || snapshot["email"].blank?
            result
          rescue ArgumentError, TypeError
            raise InvalidPayload, "seller and buyer pin codes must be numeric"
          end

          def item(line)
            ensure_quantity_precision!(line)
            components = line.tax_components
            row = {
              "SlNo" => line.line_no.to_s,
              "PrdDesc" => line.item_snapshot.fetch("name"),
              "IsServc" => line.item_snapshot.fetch("itemType") == "service" ? "Y" : "N",
              "HsnCd" => line.hsn_sac_code,
              "Qty" => decimal(line.quantity),
              "Unit" => line.item_snapshot.fetch("unitOfMeasure"),
              "UnitPrice" => EInvoice.rupees(line.unit_price_minor),
              "TotAmt" => EInvoice.rupees(line.taxable_minor),
              "AssAmt" => EInvoice.rupees(line.taxable_minor),
              "GstRt" => EInvoice.percentage(line.tax_rate_basis_points),
              "IgstAmt" => EInvoice.rupees(components.fetch("igst", 0)),
              "CgstAmt" => EInvoice.rupees(components.fetch("cgst", 0)),
              "SgstAmt" => EInvoice.rupees(
                components.fetch("sgst", 0).to_i + components.fetch("utgst", 0).to_i
              ),
              "TotItemVal" => EInvoice.rupees(
                line.taxable_minor + components.values.sum(&:to_i)
              )
            }
            if line.cess_rate_basis_points.positive?
              row["CesRt"] = EInvoice.percentage(line.cess_rate_basis_points)
              row["CesAmt"] = EInvoice.rupees(components.fetch("cess", 0))
            end
            row
          end

          def value_details(document)
            tax = document.tax_breakdown
            {
              "AssVal" => EInvoice.rupees(document.subtotal_minor),
              "CgstVal" => EInvoice.rupees(tax.fetch("cgst", 0)),
              "SgstVal" => EInvoice.rupees(
                tax.fetch("sgst", 0).to_i + tax.fetch("utgst", 0).to_i
              ),
              "IgstVal" => EInvoice.rupees(tax.fetch("igst", 0)),
              "CesVal" => EInvoice.rupees(tax.fetch("cess", 0)),
              "TotInvVal" => EInvoice.rupees(document.total_minor)
            }
          end

          def decimal(value)
            value.frac.zero? ? value.to_i : value.to_f.round(3)
          end

          def ensure_quantity_precision!(line)
            return if (line.quantity * 1_000).frac.zero?

            raise NotReady,
              "#{line.document.document_number} line #{line.line_no} quantity exceeds INV-01's three-decimal precision"
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
        end
      end
    end
  end
end
