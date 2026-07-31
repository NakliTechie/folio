# frozen_string_literal: true

module Reports
  # Book-derived preparation views for GSTR-1 and GSTR-3B. These deliberately stop short of
  # filing claims: outward tables come from Folio's governed documents, while purchase-book GST
  # is only a reference until it has been reconciled to GSTR-2B and reviewed for eligibility.
  class GstReturns
    COMPONENTS = %w[igst cgst sgst utgst cess].freeze

    class << self
      def call(tenant_id:, tax_registration_id:, from_date:, to_date:)
        raise ArgumentError, "from date must be on or before the to date" if from_date > to_date

        registration = TaxRegistration.where(tenant_id: tenant_id, kind: "GSTIN")
          .find(tax_registration_id)
        documents = Document.where(
          tenant_id: tenant_id,
          tax_registration_id: registration.id,
          document_date: from_date..to_date,
          doc_type: %w[SI CN PB]
        ).where.not(posted_entry_id: nil).includes(:document_lines, :reverses, :credit_note_for)
          .order(:document_date, :id).to_a
        negative_posting_entries = EntryLine.where(
          entry_id: documents.map(&:posted_entry_id), is_negative_posting: true
        ).distinct.pluck(:entry_id).index_with(true)

        invoices = documents.select do |document|
          document.doc_type == "SI" && !negative_posting_entries.key?(document.posted_entry_id)
        end
        credit_notes = documents.select { |document| document.doc_type == "CN" }
        sales_reversals = documents.select do |document|
          document.doc_type == "SI" && negative_posting_entries.key?(document.posted_entry_id)
        end
        purchase_bills = documents.select { |document| document.doc_type == "PB" }

        table_4a = document_table(invoices, effect: 1)
        table_9b = document_table(credit_notes, effect: 1)
        reversal_adjustments = document_table(sales_reversals, effect: -1)
        reportable_net = add_totals(table_4a.fetch(:totals), negate_totals(table_9b.fetch(:totals)))
        book_outward = add_totals(reportable_net, reversal_adjustments.fetch(:totals))
        input_tax = purchase_input_tax(purchase_bills, negative_posting_entries)

        {
          registration: registration_json(registration),
          period: { from_date: from_date, to_date: to_date },
          gstr_1: {
            table_4a_b2b_regular: table_4a,
            table_9b_credit_notes_registered: table_9b,
            hsn_summary: hsn_summary(invoices, credit_notes),
            reportable_net: reportable_net,
            internal_reversal_review: reversal_adjustments,
            book_adjusted_outward: book_outward
          },
          gstr_3b: {
            table_3_1_a_outward_taxable: book_outward,
            table_4_a_5_book_input_tax_reference: input_tax,
            input_tax_status: "requires_gstr_2b_and_eligibility_review"
          },
          preparation_status: "review_required_before_filing"
        }
      end

      private

      def document_table(documents, effect:)
        rows = documents.map { |document| document_row(document, effect: effect) }
        { document_count: rows.size, rows: rows, totals: sum_rows(rows) }
      end

      def document_row(document, effect:)
        components = component_hash(document.tax_breakdown)
        {
          document_id: document.id,
          document_number: document.document_number,
          document_date: document.document_date,
          recipient_gstin: document.party_snapshot&.fetch("gstin", nil),
          recipient_name: document.party_snapshot&.fetch("name", nil),
          place_of_supply_state_code: document.place_of_supply_state_code,
          source_document_number: document.credit_note_for&.document_number || document.reverses&.document_number,
          taxable_value_minor: effect * document.subtotal_minor,
          invoice_value_minor: effect * document.total_minor,
          tax: components.transform_values { |amount| effect * amount }
        }
      end

      def sum_rows(rows)
        totals = empty_totals
        rows.each do |row|
          totals[:taxable_value_minor] += row.fetch(:taxable_value_minor)
          totals[:invoice_value_minor] += row.fetch(:invoice_value_minor)
          COMPONENTS.each { |component| totals[:tax][component.to_sym] += row.dig(:tax, component.to_sym) }
        end
        totals
      end

      def empty_totals
        {
          taxable_value_minor: 0,
          invoice_value_minor: 0,
          tax: COMPONENTS.index_with { 0 }.transform_keys(&:to_sym)
        }
      end

      def component_hash(breakdown)
        COMPONENTS.index_with { |component| breakdown&.fetch(component, 0).to_i }.transform_keys(&:to_sym)
      end

      def add_totals(left, right)
        {
          taxable_value_minor: left.fetch(:taxable_value_minor) + right.fetch(:taxable_value_minor),
          invoice_value_minor: left.fetch(:invoice_value_minor) + right.fetch(:invoice_value_minor),
          tax: COMPONENTS.index_with do |component|
            left.dig(:tax, component.to_sym) + right.dig(:tax, component.to_sym)
          end.transform_keys(&:to_sym)
        }
      end

      def negate_totals(totals)
        {
          taxable_value_minor: -totals.fetch(:taxable_value_minor),
          invoice_value_minor: -totals.fetch(:invoice_value_minor),
          tax: totals.fetch(:tax).transform_values { |amount| -amount }
        }
      end

      def hsn_summary(invoices, credit_notes)
        groups = {}
        documents_with_effect = invoices.map { |document| [ document, 1 ] } +
          credit_notes.map { |document| [ document, -1 ] }
        documents_with_effect.each do |document, effect|
          document.document_lines.each do |line|
            key = [ line.hsn_sac_code, line.item_snapshot.fetch("unitOfMeasure"), line.tax_rate_basis_points ]
            row = groups[key] ||= {
              hsn_sac_code: line.hsn_sac_code,
              uom: line.item_snapshot.fetch("unitOfMeasure"),
              tax_rate_basis_points: line.tax_rate_basis_points,
              quantity: 0.to_d,
              taxable_value_minor: 0,
              tax: COMPONENTS.index_with { 0 }.transform_keys(&:to_sym)
            }
            row[:quantity] += effect * line.quantity
            row[:taxable_value_minor] += effect * line.taxable_minor
            component_hash(line.tax_components).each do |component, amount|
              row[:tax][component] += effect * amount
            end
          end
        end
        groups.values.sort_by { |row| [ row.fetch(:hsn_sac_code), row.fetch(:tax_rate_basis_points) ] }
      end

      def purchase_input_tax(documents, negative_posting_entries)
        components = COMPONENTS.index_with { 0 }.transform_keys(&:to_sym)
        taxable = 0
        invoice_value = 0
        documents.each do |document|
          effect = negative_posting_entries.key?(document.posted_entry_id) ? -1 : 1
          taxable += effect * document.subtotal_minor
          invoice_value += effect * document.total_minor
          component_hash(document.tax_breakdown).each do |component, amount|
            components[component] += effect * amount
          end
        end
        {
          document_count: documents.count { |document| !negative_posting_entries.key?(document.posted_entry_id) },
          reversal_count: documents.count { |document| negative_posting_entries.key?(document.posted_entry_id) },
          taxable_value_minor: taxable,
          invoice_value_minor: invoice_value,
          tax: components
        }
      end

      def registration_json(registration)
        {
          id: registration.id,
          gstin: registration.identifier,
          state_code: registration.state_code,
          jurisdiction: registration.jurisdiction
        }
      end
    end
  end
end
