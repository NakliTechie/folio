# frozen_string_literal: true

module Posting
  module Rules
    # Records a supplier-issued credit against a governed purchase bill. It reduces the
    # payable, expense, and input-GST balances while preserving a separate open vendor credit
    # if the source bill has already been partly paid.
    class PurchaseCreditNote
      PAYABLE_ACCOUNT_CODE = PurchaseBill::PAYABLE_ACCOUNT_CODE
      INPUT_TAX_ACCOUNT_CODE = PurchaseBill::INPUT_TAX_ACCOUNT_CODE

      class << self
        def lock_dependencies!(document)
          Document.where(tenant_id: document.tenant_id).lock.find(document.credit_note_for_document_id)
        end

        def validate_document!(document)
          source = document.credit_note_for
          unless source && source.tenant_id == document.tenant_id && source.doc_type == "PB" && source.state == "posted"
            raise Documents::InvalidDocument,
              "a supplier credit note needs a posted purchase bill from the same company"
          end
          unless PurchaseCreditNotes::BuildDraft::REASONS.include?(document.reason_code)
            raise Documents::InvalidDocument, "supplier-credit reason is unavailable"
          end
          if document.external_reference.blank?
            raise Documents::InvalidDocument, "supplier credit-note number is missing"
          end
          unless document.document_date >= source.document_date && header_matches_source?(document, source)
            raise Documents::InvalidDocument, "supplier-credit identity does not match its purchase bill"
          end

          validate_lines!(document, source)
        end

        def entry_lines(document)
          validate_document!(document)
          ledger = Ledger.find_by!(tenant_id: document.tenant_id, code: "PRIMARY")
          amount = ->(value) { transaction_amount(document, value) }
          line_no = 0

          vendor_line = {
            line_no: line_no += 1,
            account_code: PAYABLE_ACCOUNT_CODE,
            ledger_id: ledger.id,
            entity_id: document.entity_id,
            office_id: document.office_id,
            party_id: document.party_id,
            party_role: "vendor",
            open_item: true,
            item_class: "normal",
            assignment: "PC:#{document.id}",
            baseline_date: document.document_date,
            due_date: document.document_date,
            extra: {
              "partySnapshot" => document.party_snapshot,
              "sourcePurchaseBillId" => document.credit_note_for_document_id,
              "supplierCreditNoteNumber" => document.external_reference
            },
            amounts: [ amount.call(document.total_minor) ]
          }

          expense_lines = document.document_lines.map do |line|
            {
              line_no: line_no += 1,
              account_code: line.account_code,
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
                "creditedDocumentLineId" => line.credited_document_line_id
              },
              amounts: [ amount.call(-line.taxable_minor) ]
            }
          end

          tax_lines = document.document_lines.flat_map do |line|
            line.tax_components.sort.filter_map do |component, component_amount|
              next if component_amount.to_i.zero?

              {
                line_no: line_no += 1,
                account_code: INPUT_TAX_ACCOUNT_CODE,
                ledger_id: ledger.id,
                entity_id: document.entity_id,
                office_id: document.office_id,
                tax_registration_id: document.tax_registration_id,
                item_id: line.item_id,
                hsn_sac_code: line.hsn_sac_code,
                tax_component: component,
                tax_rate_basis_points: component_rate(line, component),
                taxable_amount_minor: line.taxable_minor,
                amounts: [ amount.call(-Integer(component_amount)) ]
              }
            end
          end

          [ vendor_line, *expense_lines, *tax_lines ]
        end

        def after_post!(document:, entry:, actor:)
          bill_line = EntryLine.find_by(
            entry_id: document.credit_note_for.posted_entry_id,
            account_code: PAYABLE_ACCOUNT_CODE
          )
          credit_line = entry.entry_lines.find_by!(account_code: PAYABLE_ACCOUNT_CODE)
          bill_outstanding = open_outstanding(bill_line)
          credit_outstanding = Posting::Clearing.open_amount(credit_line)
          applied = [ bill_outstanding, credit_outstanding ].min
          return if applied.zero?

          Posting::Clearing.clear!(
            item: bill_line,
            amount_minor: applied,
            cleared_on: document.document_date,
            mode: applied == bill_outstanding ? :full : :partial,
            clearing_entry: entry,
            actor: actor,
            reason: "supplier credit note #{document.id}"
          )
          Posting::Clearing.clear!(
            item: credit_line,
            amount_minor: applied,
            cleared_on: document.document_date,
            mode: applied == credit_outstanding ? :full : :partial,
            clearing_entry: entry,
            actor: actor,
            reason: "applied to purchase bill #{document.credit_note_for_document_id}"
          )
        end

        private

        def header_matches_source?(document, source)
          %i[
            entity_id office_id party_id tax_registration_id supply_type place_of_supply_state_code
            currency minor_unit_exponent party_snapshot tax_registration_snapshot
          ].all? { |attribute| document.public_send(attribute) == source.public_send(attribute) }
        end

        def validate_lines!(document, source)
          lines = document.document_lines.to_a
          raise Documents::InvalidDocument, "a supplier credit note needs at least one line" if lines.empty?
          if lines.map(&:credited_document_line_id).uniq.size != lines.size
            raise Documents::InvalidDocument, "each purchase-bill line may appear only once on a supplier credit note"
          end

          source_lines = source.document_lines.index_by(&:id)
          subtotal = 0
          tax_total = 0
          breakdown = Hash.new(0)
          lines.each do |line|
            original = source_lines[line.credited_document_line_id]
            unless original && frozen_line_matches?(line, original)
              raise Documents::InvalidDocument,
                "supplier-credit line #{line.line_no} does not match its purchase-bill line"
            end
            remaining = PurchaseCreditNotes::BuildDraft.remaining_values(
              original, excluding_document_id: document.id
            )
            unless line.quantity.positive? && line.quantity <= remaining.fetch(:quantity)
              raise Documents::InvalidDocument,
                "supplier-credit line #{line.line_no} exceeds the uncredited quantity"
            end
            values = PurchaseCreditNotes::BuildDraft.credit_values(
              source, original, line.quantity, remaining
            )
            taxable = values.fetch(:taxable_minor)
            unless taxable == line.taxable_minor && line.amount_minor == -taxable
              raise Documents::InvalidDocument, "supplier-credit line #{line.line_no} value was altered"
            end

            expected = values.fetch(:tax_components)
            unless line.tax_components.transform_values(&:to_i) == expected
              raise Documents::InvalidDocument, "supplier-credit line #{line.line_no} tax was altered"
            end
            subtotal += taxable
            expected.each { |component, value| breakdown[component] += value }
            tax_total += expected.values.sum
          end
          unless document.subtotal_minor == subtotal && document.tax_minor == tax_total &&
                 document.total_minor == subtotal + tax_total &&
                 document.tax_breakdown.transform_values(&:to_i) == breakdown
            raise Documents::InvalidDocument, "supplier-credit totals do not match its frozen lines"
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
              "supplier-credit line #{line.line_no} GST rate cannot be split exactly"
          end
          line.tax_rate_basis_points / 2
        end

        def transaction_amount(document, amount_minor)
          {
            slot_role: "transaction",
            currency: document.currency,
            minor_unit_exponent: document.minor_unit_exponent,
            amount_minor: amount_minor
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
