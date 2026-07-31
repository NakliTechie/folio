# frozen_string_literal: true

module PurchaseDebitNotes
  # Builds an increasing-liability adjustment from immutable purchase-bill lines. The
  # supplier's debit-note reference remains external; Folio allocates a separate PD number.
  module BuildDraft
    REASONS = %w[price_increase additional_charge underbilling other].freeze

    module_function

    def call(tenant:, purchase_bill_id:, document_date:, external_reference:, reason_code:, lines:, narration: nil)
      date = parse_date!(document_date)
      reason = reason_code.to_s
      raise InvalidDebitNote, "choose a supported supplier-debit reason" unless REASONS.include?(reason)
      supplier_reference = external_reference.to_s.strip.upcase
      if supplier_reference.blank? || supplier_reference.length > 100
        raise InvalidDebitNote, "supplier debit-note number is required and may be no more than 100 characters"
      end

      bill = Document.includes(:document_lines).where(
        tenant_id: tenant.id, doc_type: "PB", state: "posted"
      ).find(purchase_bill_id)
      raise InvalidDebitNote, "supplier debit-note date cannot precede the purchase bill" if date < bill.document_date
      if Document.where(
        tenant_id: tenant.id, party_id: bill.party_id, doc_type: "PD", external_reference: supplier_reference
      ).exists?
        raise InvalidDebitNote, "this supplier debit-note number is already recorded for the vendor"
      end

      entity = Entity.find_by!(tenant_id: tenant.id, id: bill.entity_id)
      type = DocumentType.where(tenant_id: tenant.id, active: true).find_by!(
        code: "PD", posting_rule: "purchase_debit_note"
      )
      normalized_lines = normalize_lines!(bill, lines)
      subtotal = normalized_lines.sum { |line| line.fetch(:taxable_minor) }
      breakdown = normalized_lines.each_with_object(Hash.new(0)) do |line, result|
        line.fetch(:tax_components).each { |component, value| result[component] += value }
      end
      tax_total = breakdown.values.sum

      Document.transaction do
        note = Document.create!(
          tenant_id: tenant.id, entity_id: bill.entity_id, office_id: bill.office_id,
          doc_type: type.code, document_type: type,
          fiscal_year: Documents.fiscal_year(date, variant: entity.fiscal_year_variant),
          document_date: date, posting_date: date, due_date: date,
          external_reference: supplier_reference, state: "draft",
          debit_note_for: bill, reason_code: reason, narration: narration,
          party_id: bill.party_id, tax_registration_id: bill.tax_registration_id,
          supply_type: bill.supply_type,
          place_of_supply_state_code: bill.place_of_supply_state_code,
          currency: bill.currency, minor_unit_exponent: bill.minor_unit_exponent,
          subtotal_minor: subtotal, tax_minor: tax_total, total_minor: subtotal + tax_total,
          party_snapshot: bill.party_snapshot,
          tax_registration_snapshot: bill.tax_registration_snapshot,
          tax_breakdown: breakdown
        )
        normalized_lines.each_with_index do |line, index|
          source = line.fetch(:source)
          note.document_lines.create!(
            tenant_id: tenant.id, line_no: index + 1,
            debited_document_line: source,
            account_code: source.account_code, amount_minor: line.fetch(:taxable_minor),
            currency: bill.currency, minor_unit_exponent: bill.minor_unit_exponent,
            narration: source.narration, item_id: source.item_id,
            quantity: line.fetch(:quantity), unit_price_minor: source.unit_price_minor,
            taxable_minor: line.fetch(:taxable_minor), hsn_sac_code: source.hsn_sac_code,
            tax_rate_basis_points: source.tax_rate_basis_points,
            cess_rate_basis_points: source.cess_rate_basis_points,
            tax_components: line.fetch(:tax_components), item_snapshot: source.item_snapshot
          )
        end
        Posting::Rules::PurchaseDebitNote.validate_document!(note)
        note
      end
    rescue ActiveRecord::RecordNotFound => e
      raise InvalidDebitNote, "the source bill or supplier-debit type is unavailable: #{e.model}"
    rescue ActiveRecord::RecordNotUnique
      raise InvalidDebitNote, "this supplier debit-note number is already recorded for the vendor"
    end

    def normalize_lines!(bill, raw_lines)
      rows = Array(raw_lines).reject do |line|
        value(line, :document_line_id).blank? || value(line, :quantity).blank?
      end
      raise InvalidDebitNote, "add at least one supplier-debit line" if rows.empty?

      source_lines = bill.document_lines.index_by { |line| line.id.to_s }
      rows.map do |line|
        source = source_lines[value(line, :document_line_id).to_s]
        raise InvalidDebitNote, "a selected line does not belong to the purchase bill" unless source

        quantity = decimal!(value(line, :quantity), "debit quantity for line #{source.line_no}")
        raise InvalidDebitNote, "debit quantity for line #{source.line_no} must be positive" unless quantity.positive?

        taxable = (quantity * source.unit_price_minor).round(0, BigDecimal::ROUND_HALF_UP).to_i
        raise InvalidDebitNote, "debit value for line #{source.line_no} must be positive" unless taxable.positive?
        tax = Taxes::India::Adapter.calculate(
          taxable_minor: taxable,
          rate_basis_points: source.tax_rate_basis_points,
          cess_rate_basis_points: source.cess_rate_basis_points,
          supplier_state_code: bill.party_snapshot.fetch("gstinStateCode"),
          place_of_supply_state_code: bill.place_of_supply_state_code
        )
        {
          source: source, quantity: quantity, taxable_minor: taxable,
          tax_components: tax.components.transform_keys(&:to_s)
        }
      end
    end

    def decimal!(value, label)
      decimal = BigDecimal(value.to_s)
      raise InvalidDebitNote, "#{label} may have no more than six decimal places" if decimal.scale > 6

      decimal
    rescue ArgumentError
      raise InvalidDebitNote, "#{label} must be a number"
    end

    def parse_date!(value)
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    rescue Date::Error
      raise InvalidDebitNote, "supplier debit-note date must be a valid ISO date"
    end

    def value(hash, key) = hash[key] || hash[key.to_s]
  end
end
