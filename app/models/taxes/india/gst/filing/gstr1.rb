# frozen_string_literal: true

module Taxes
  module India
    module Gst
      module Filing
        # GSTN GSTR1 Save v5.0 profile for Folio's currently governed B2B invoices and
        # registered credit notes. Unsupported outward categories fail closed.
        module Gstr1
          module_function

          def call(tenant_id:, tax_registration_id:, from_date:, to_date:)
            Filing.regular_period!(from_date, to_date)
            registration = TaxRegistration.where(tenant_id: tenant_id, kind: "GSTIN")
              .find(tax_registration_id)
            invoices, notes = source_documents(
              tenant_id: tenant_id,
              registration_id: registration.id,
              from_date: from_date,
              to_date: to_date
            )
            validate_supported!(invoices + notes)

            payload = {
              "gstin" => registration.identifier,
              "fp" => Filing.return_period(to_date)
            }
            b2b = b2b_rows(invoices)
            cdnr = cdnr_rows(notes)
            hsn = hsn_rows(invoices, notes)
            docs = document_issue(invoices, notes)
            payload["b2b"] = b2b if b2b.any?
            payload["cdnr"] = cdnr if cdnr.any?
            payload["hsn"] = { "hsn_b2b" => hsn } if hsn.any?
            payload["doc_issue"] = { "doc_det" => docs } if docs.any?

            crosscheck = crosscheck!(
              tenant_id: tenant_id,
              registration_id: registration.id,
              from_date: from_date,
              to_date: to_date,
              invoices: invoices,
              notes: notes
            )
            Filing.result(form: "GSTR1", payload: payload, crosscheck: crosscheck)
          end

          def source_documents(tenant_id:, registration_id:, from_date:, to_date:)
            documents = Document.where(
              tenant_id: tenant_id,
              tax_registration_id: registration_id,
              document_date: from_date..to_date,
              doc_type: %w[SI CN]
            ).where.not(posted_entry_id: nil).includes(:document_lines).order(:document_date, :id).to_a
            negative_ids = EntryLine.where(
              entry_id: documents.map(&:posted_entry_id), is_negative_posting: true
            ).distinct.pluck(:entry_id)
            if negative_ids.any?
              raise NotReady,
                "GSTR-1 export contains an internal invoice reversal; issue a governed credit note before filing"
            end

            [ documents.select { |document| document.doc_type == "SI" },
              documents.select { |document| document.doc_type == "CN" } ]
          end

          def validate_supported!(documents)
            unsupported = documents.reject do |document|
              document.supply_type == "B2B" &&
                Taxes::India::Gstin.valid?(document.party_snapshot.to_h["gstin"]) &&
                document.place_of_supply_state_code.present?
            end
            return if unsupported.empty?

            raise NotReady,
              "GSTR-1 export currently supports regular registered B2B supplies only; " \
              "unsupported documents: #{unsupported.map(&:document_number).join(', ')}"
          end

          def b2b_rows(invoices)
            invoices.group_by { |document| document.party_snapshot.fetch("gstin") }
              .sort_by(&:first).map do |gstin, documents|
                {
                  "ctin" => gstin,
                  "inv" => documents.map { |document| invoice_row(document) }
                }
              end
          end

          def invoice_row(document)
            {
              "inum" => document.document_number,
              "idt" => Filing.gst_date(document.document_date),
              "val" => Filing.rupees(document.total_minor),
              "pos" => document.place_of_supply_state_code,
              "rchrg" => "N",
              "inv_typ" => "R",
              "itms" => document.document_lines.each_with_index.map do |line, index|
                item_row(line, index + 1)
              end
            }
          end

          def cdnr_rows(notes)
            notes.group_by { |document| document.party_snapshot.fetch("gstin") }
              .sort_by(&:first).map do |gstin, documents|
                {
                  "ctin" => gstin,
                  "nt" => documents.map { |document| note_row(document) }
                }
              end
          end

          def note_row(document)
            {
              "ntty" => "C",
              "nt_num" => document.document_number,
              "nt_dt" => Filing.gst_date(document.document_date),
              "val" => Filing.rupees(document.total_minor),
              "pos" => document.place_of_supply_state_code,
              "rchrg" => "N",
              "inv_typ" => "R",
              "itms" => document.document_lines.each_with_index.map do |line, index|
                item_row(line, index + 1)
              end
            }
          end

          def item_row(line, number)
            details = {
              "txval" => Filing.rupees(line.taxable_minor),
              "rt" => percentage(line.tax_rate_basis_points)
            }
            add_tax_components!(details, line.tax_components)
            { "num" => number, "itm_det" => details }
          end

          def hsn_rows(invoices, notes)
            groups = {}
            [ *invoices.map { |document| [ document, 1 ] },
              *notes.map { |document| [ document, -1 ] } ].each do |document, sign|
              document.document_lines.each do |line|
                ensure_hsn_quantity_precision!(line)
                key = [ line.hsn_sac_code, line.item_snapshot.fetch("unitOfMeasure"),
                        line.tax_rate_basis_points ]
                row = groups[key] ||= {
                  "hsn_sc" => line.hsn_sac_code,
                  "uqc" => line.item_snapshot.fetch("unitOfMeasure"),
                  "qty_minor" => 0,
                  "txval_minor" => 0,
                  "tax_minor" => Hash.new(0),
                  "rt" => percentage(line.tax_rate_basis_points)
                }
                row["qty_minor"] += sign * (line.quantity * 100).to_i
                row["txval_minor"] += sign * line.taxable_minor
                line.tax_components.each do |component, amount|
                  row["tax_minor"][component] += sign * amount.to_i
                end
              end
            end
            groups.values.sort_by { |row| [ row.fetch("hsn_sc"), row.fetch("rt") ] }
              .each_with_index.map do |row, index|
                result = {
                  "num" => index + 1,
                  "hsn_sc" => row.fetch("hsn_sc"),
                  "uqc" => row.fetch("uqc"),
                  "qty" => Filing.rupees(row.fetch("qty_minor")),
                  "txval" => Filing.rupees(row.fetch("txval_minor")),
                  "rt" => row.fetch("rt")
                }
                add_tax_components!(result, row.fetch("tax_minor"))
                result
              end
          end

          def document_issue(invoices, notes)
            [ [ 1, invoices ], [ 5, notes ] ].filter_map do |document_code, documents|
              next if documents.empty?

              numbers = documents.map(&:document_number).sort
              {
                "doc_num" => document_code,
                "docs" => [ {
                  "num" => 1,
                  "from" => numbers.first,
                  "to" => numbers.last,
                  "totnum" => numbers.size,
                  "cancel" => 0,
                  "net_issue" => numbers.size
                } ]
              }
            end
          end

          def crosscheck!(tenant_id:, registration_id:, from_date:, to_date:, invoices:, notes:)
            preparation = Reports::GstReturns.call(
              tenant_id: tenant_id,
              tax_registration_id: registration_id,
              from_date: from_date,
              to_date: to_date
            )
            expected = preparation.dig(:gstr_1, :reportable_net)
            taxable = invoices.sum(&:subtotal_minor) - notes.sum(&:subtotal_minor)
            tax = Reports::GstReturns::COMPONENTS.to_h do |component|
              [ component.to_sym,
                invoices.sum { |document| document.tax_breakdown.fetch(component, 0).to_i } -
                  notes.sum { |document| document.tax_breakdown.fetch(component, 0).to_i } ]
            end
            unless expected.fetch(:taxable_value_minor) == taxable && expected.fetch(:tax) == tax
              raise InvalidPayload, "GSTR-1 filing payload does not reconcile to the preparation report"
            end

            {
              status: "matched",
              source: "folio_posted_documents",
              invoice_count: invoices.size,
              credit_note_count: notes.size,
              taxable_value_minor: taxable,
              tax_minor: tax
            }
          end

          def add_tax_components!(target, components)
            { "igst" => "iamt", "cgst" => "camt", "sgst" => "samt",
              "utgst" => "samt", "cess" => "csamt" }.each do |source, destination|
              amount = components.fetch(source, 0).to_i
              next if amount.zero?

              existing_minor = (target.fetch(destination, 0).to_d * 100).to_i
              target[destination] = Filing.rupees(existing_minor + amount)
            end
            target
          end

          def percentage(basis_points)
            basis_points % 100 == 0 ? basis_points / 100 : (basis_points / 100.0).round(2)
          end

          def ensure_hsn_quantity_precision!(line)
            return if (line.quantity * 100).frac.zero?

            raise NotReady,
              "#{line.document.document_number} line #{line.line_no} quantity exceeds GSTN's two-decimal HSN precision"
          end
        end
      end
    end
  end
end
