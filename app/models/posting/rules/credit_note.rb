# frozen_string_literal: true

module Posting
  module Rules
    class CreditNote
      RECEIVABLE_ACCOUNT_CODE = "1200"
      TAX_ACCOUNT_CODE = "2100"
      CONTRACT_LIABILITY_ACCOUNT_CODE = "2200"

      class << self
        def lock_dependencies!(document)
          Document.where(tenant_id: document.tenant_id).lock.find(document.credit_note_for_document_id)
        end

        def validate_document!(document)
          source = document.credit_note_for
          unless source && source.tenant_id == document.tenant_id && source.doc_type == "SI" && source.state == "posted"
            raise Documents::InvalidDocument, "a credit note needs a posted sales invoice from the same company"
          end
          unless CreditNotes::BuildDraft::REASONS.include?(document.reason_code)
            raise Documents::InvalidDocument, "credit-note reason is unavailable"
          end
          unless document.document_date >= source.document_date && header_matches_source?(document, source)
            raise Documents::InvalidDocument, "credit-note identity does not match its source invoice"
          end

          validate_lines!(document, source)
        end

        def entry_lines(document)
          validate_document!(document)
          ledger = Ledger.find_by!(tenant_id: document.tenant_id, code: "PRIMARY")
          amount = ->(value) { transaction_amount(document, value) }
          line_no = 0

          customer_line = {
            line_no: line_no += 1,
            account_code: RECEIVABLE_ACCOUNT_CODE,
            ledger_id: ledger.id,
            entity_id: document.entity_id,
            office_id: document.office_id,
            party_id: document.party_id,
            party_role: "customer",
            open_item: true,
            item_class: "normal",
            assignment: "CN:#{document.id}",
            baseline_date: document.document_date,
            due_date: document.document_date,
            extra: {
              "partySnapshot" => document.party_snapshot,
              "placeOfSupplyEvidence" => document.place_of_supply_evidence,
              "sourceInvoiceId" => document.credit_note_for_document_id
            },
            amounts: [ amount.call(-document.total_minor) ]
          }

          revenue_lines = document.document_lines.map do |line|
            {
              line_no: line_no += 1,
              account_code: document.contract_id ? CONTRACT_LIABILITY_ACCOUNT_CODE : line.account_code,
              ledger_id: ledger.id,
              entity_id: document.entity_id,
              office_id: document.office_id,
              tax_registration_id: document.tax_registration_id,
              item_id: line.item_id,
              quantity: line.quantity,
              uom: line.item_snapshot.fetch("unitOfMeasure"),
              hsn_sac_code: line.hsn_sac_code,
              tax_rate_basis_points: line.tax_rate_basis_points,
              taxable_amount_minor: line.taxable_minor,
              extra: {
                "itemSnapshot" => line.item_snapshot,
                "creditedDocumentLineId" => line.credited_document_line_id,
                "contractSnapshot" => document.contract_snapshot
              }.compact,
              amounts: [ amount.call(line.taxable_minor) ]
            }
          end

          tax_lines = document.document_lines.flat_map do |line|
            line.tax_components.sort.filter_map do |component, component_amount|
              next if component_amount.to_i.zero?

              {
                line_no: line_no += 1,
                account_code: TAX_ACCOUNT_CODE,
                ledger_id: ledger.id,
                entity_id: document.entity_id,
                office_id: document.office_id,
                tax_registration_id: document.tax_registration_id,
                item_id: line.item_id,
                hsn_sac_code: line.hsn_sac_code,
                tax_component: component,
                tax_rate_basis_points: component_rate(line, component),
                taxable_amount_minor: line.taxable_minor,
                amounts: [ amount.call(Integer(component_amount)) ]
              }
            end
          end

          [ customer_line, *revenue_lines, *tax_lines ]
        end

        def after_post!(document:, entry:, actor:)
          invoice_line = EntryLine.find_by(entry_id: document.credit_note_for.posted_entry_id,
            account_code: RECEIVABLE_ACCOUNT_CODE)
          credit_line = EntryLine.find_by!(entry_id: entry.id, account_code: RECEIVABLE_ACCOUNT_CODE)
          invoice_outstanding = open_outstanding(invoice_line)
          credit_outstanding = Posting::Clearing.open_amount(credit_line)
          applied = [ invoice_outstanding, credit_outstanding ].min
          return if applied.zero?

          Posting::Clearing.clear!(
            item: invoice_line,
            amount_minor: applied,
            cleared_on: document.document_date,
            mode: applied == invoice_outstanding ? :full : :partial,
            clearing_entry: entry,
            actor: actor,
            reason: "credit note #{document.id}"
          )
          Posting::Clearing.clear!(
            item: credit_line,
            amount_minor: applied,
            cleared_on: document.document_date,
            mode: applied == credit_outstanding ? :full : :partial,
            clearing_entry: entry,
            actor: actor,
            reason: "applied to invoice #{document.credit_note_for_document_id}"
          )
        end

        private

        def header_matches_source?(document, source)
          %i[
            entity_id office_id party_id tax_registration_id supply_type place_of_supply_state_code
            currency minor_unit_exponent party_snapshot tax_registration_snapshot place_of_supply_evidence
            contract_id contract_snapshot
          ].all? { |attribute| document.public_send(attribute) == source.public_send(attribute) }
        end

        def validate_lines!(document, source)
          lines = document.document_lines.to_a
          raise Documents::InvalidDocument, "a credit note needs at least one line" if lines.empty?
          if lines.map(&:credited_document_line_id).uniq.size != lines.size
            raise Documents::InvalidDocument, "each invoice line may appear only once on a credit note"
          end

          source_lines = source.document_lines.index_by(&:id)
          subtotal = 0
          tax_total = 0
          breakdown = Hash.new(0)
          lines.each do |line|
            original = source_lines[line.credited_document_line_id]
            unless original && frozen_line_matches?(line, original)
              raise Documents::InvalidDocument, "credit-note line #{line.line_no} does not match its invoice line"
            end
            remaining = CreditNotes::BuildDraft.remaining_values(original)
            unless line.quantity.positive? && line.quantity <= remaining.fetch(:quantity)
              raise Documents::InvalidDocument, "credit-note line #{line.line_no} exceeds the uncredited quantity"
            end
            values = CreditNotes::BuildDraft.credit_values(source, original, line.quantity, remaining)
            taxable = values.fetch(:taxable_minor)
            unless taxable == line.taxable_minor && line.amount_minor == taxable
              raise Documents::InvalidDocument, "credit-note line #{line.line_no} value was altered"
            end

            expected = values.fetch(:tax_components)
            unless line.tax_components.transform_values(&:to_i) == expected
              raise Documents::InvalidDocument, "credit-note line #{line.line_no} tax was altered"
            end

            subtotal += taxable
            expected.each { |component, value| breakdown[component] += value }
            tax_total += expected.values.sum
          end
          unless document.subtotal_minor == subtotal && document.tax_minor == tax_total &&
                 document.total_minor == subtotal + tax_total &&
                 document.tax_breakdown.transform_values(&:to_i) == breakdown
            raise Documents::InvalidDocument, "credit-note totals do not match its frozen lines"
          end
        end

        def frozen_line_matches?(line, original)
          %i[
            tenant_id account_code currency minor_unit_exponent item_id unit_price_minor hsn_sac_code
            tax_rate_basis_points cess_rate_basis_points item_snapshot
          ].all? { |attribute| line.public_send(attribute) == original.public_send(attribute) }
        end

        def component_rate(line, component)
          return line.cess_rate_basis_points if component == "cess"
          return line.tax_rate_basis_points if component == "igst"

          unless line.tax_rate_basis_points.even?
            raise Documents::InvalidDocument,
              "credit-note line #{line.line_no} GST rate cannot be split exactly"
          end
          line.tax_rate_basis_points / 2
        end

        def transaction_amount(document, amount_minor)
          {
            slot_role: "transaction", currency: document.currency,
            minor_unit_exponent: document.minor_unit_exponent, amount_minor: amount_minor
          }
        end

        def open_outstanding(line)
          return 0 unless line&.open_item? && line.cleared_on.nil?

          Posting::Clearing.open_amount(line)
        end
      end
    end
  end
end
