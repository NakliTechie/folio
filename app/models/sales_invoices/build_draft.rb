# frozen_string_literal: true

module SalesInvoices
  # Resolves all mutable masters exactly once and freezes their invoice-relevant values into the
  # draft. Posting uses only these snapshots plus stable codes/ids; replay uses the fat event.
  module BuildDraft
    module_function

    def call(tenant:, party_id:, tax_registration_id:, document_date:, due_date:,
             place_of_supply_state_code:, lines:, external_reference: nil, narration: nil,
             place_of_supply_override_reason: nil, actor: nil)
      invoice_date = parse_date!(document_date, "invoice date")
      payment_due = parse_date!(due_date, "due date")
      raise InvalidInvoice, "due date cannot be before the invoice date" if payment_due < invoice_date

      entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      unless entity.jurisdiction_profile == "IN" && tenant.functional_currency == "INR"
        raise InvalidInvoice, "sales invoices currently require an India/INR accounting profile"
      end
      office = Office.find_by!(tenant_id: tenant.id, entity_id: entity.id, code: "PRIMARY")
      unless office.statutory_address_complete? && office.country_code == "IN"
        raise InvalidInvoice, "complete India company details are required before issuing an invoice"
      end
      type = DocumentType.where(tenant_id: tenant.id, active: true).find_by!(code: "SI", posting_rule: "sales_invoice")
      party = Party.active.includes(:party_roles, :party_tax_registrations)
        .where(tenant_id: tenant.id).find(party_id)
      raise InvalidInvoice, "the selected party is not a customer" unless party.role_codes.include?("customer")
      unless party.statutory_address_complete? && party.country_code == "IN"
        raise InvalidInvoice, "the selected customer needs a complete India billing address"
      end

      party_registration = party.party_tax_registrations.in_force_on(invoice_date)
        .where(kind: "GSTIN").order(valid_from: :desc).first
      raise InvalidInvoice, "the selected customer needs a GSTIN in force on the invoice date" unless party_registration

      seller_registration = TaxRegistration.in_force_on(invoice_date)
        .joins(:office_tax_registrations)
        .where(
          tenant_id: tenant.id, entity_id: entity.id, id: tax_registration_id, kind: "GSTIN",
          office_tax_registrations: { office_id: office.id, tenant_id: tenant.id }
        ).first
      raise InvalidInvoice, "the selected seller GSTIN is unavailable for this office and date" unless seller_registration
      unless seller_registration.state_code == office.state_code
        raise InvalidInvoice, "the issuing office state must match the selected seller GSTIN"
      end

      place_state = place_of_supply_state_code.to_s
      unless Taxes::India::StateCodes.valid?(place_state)
        raise InvalidInvoice, "place of supply must be a valid GST state code"
      end
      place_evidence = Taxes::India::PlaceOfSupplyEvidence.build!(
        tenant: tenant, party: party, selected_state_code: place_state, actor: actor,
        override_reason: place_of_supply_override_reason, error_class: InvalidInvoice
      )

      normalized_lines = normalize_lines!(
        tenant: tenant, entity: entity, seller_registration: seller_registration,
        place_state: place_state, raw_lines: lines
      )
      subtotal = normalized_lines.sum { |line| line.fetch(:taxable_minor) }
      breakdown = normalized_lines.each_with_object(Hash.new(0)) do |line, result|
        line.fetch(:tax_components).each { |component, value| result[component] += value }
      end
      tax_total = breakdown.values.sum
      currency = tenant.functional_currency
      exponent = CurrencyProfile.exponent_for!(currency)

      Document.transaction do
        document = Document.create!(
          tenant_id: tenant.id, entity_id: entity.id, office_id: office.id,
          doc_type: type.code, document_type: type,
          fiscal_year: Documents.fiscal_year(invoice_date, variant: entity.fiscal_year_variant),
          document_date: invoice_date, posting_date: invoice_date, due_date: payment_due,
          external_reference: external_reference.presence, narration: narration,
          state: "draft", party: party, tax_registration: seller_registration,
          supply_type: "B2B", place_of_supply_state_code: place_state,
          place_of_supply_evidence: place_evidence,
          currency: currency, minor_unit_exponent: exponent,
          subtotal_minor: subtotal, tax_minor: tax_total, total_minor: subtotal + tax_total,
          party_snapshot: party_snapshot(party, party_registration),
          tax_registration_snapshot: registration_snapshot(seller_registration, entity, office),
          tax_breakdown: breakdown
        )
        normalized_lines.each_with_index do |line, index|
          document.document_lines.create!(
            tenant_id: tenant.id, line_no: index + 1,
            account_code: line.fetch(:account_code), amount_minor: -line.fetch(:taxable_minor),
            currency: currency, minor_unit_exponent: exponent,
            narration: line.fetch(:name), item_id: line.fetch(:item_id),
            quantity: line.fetch(:quantity), unit_price_minor: line.fetch(:unit_price_minor),
            taxable_minor: line.fetch(:taxable_minor), hsn_sac_code: line.fetch(:hsn_sac_code),
            tax_rate_basis_points: line.fetch(:tax_rate_basis_points),
            cess_rate_basis_points: line.fetch(:cess_rate_basis_points),
            tax_components: line.fetch(:tax_components), item_snapshot: line.fetch(:item_snapshot)
          )
        end
        Posting::Rules::SalesInvoice.validate_document!(document)
        document
      end
    rescue ActiveRecord::RecordNotFound => e
      raise InvalidInvoice, "an invoice master is unavailable: #{e.model}"
    end

    def normalize_lines!(tenant:, entity:, seller_registration:, place_state:, raw_lines:)
      rows = Array(raw_lines).reject { |line| value(line, :item_id).blank? }
      raise InvalidInvoice, "add at least one invoice line" if rows.empty?

      rows.map do |line|
        item = Item.active.where(tenant_id: tenant.id).find(value(line, :item_id))
        quantity = decimal!(value(line, :quantity), "quantity for #{item.code}")
        raise InvalidInvoice, "quantity for #{item.code} must be positive" unless quantity.positive?

        unit_price_minor = money_minor!(value(line, :unit_price), "unit price for #{item.code}")
        taxable = (quantity * unit_price_minor).round(0, BigDecimal::ROUND_HALF_UP).to_i
        raise InvalidInvoice, "taxable value for #{item.code} must be positive" unless taxable.positive?

        tax = Taxes.calculate(
          entity: entity, taxable_minor: taxable,
          rate_basis_points: item.tax_rate_basis_points,
          cess_rate_basis_points: item.cess_rate_basis_points,
          supplier_state_code: seller_registration.state_code,
          place_of_supply_state_code: place_state
        )
        {
          item_id: item.id, account_code: item.income_account_code,
          name: item.name, quantity: quantity, unit_price_minor: unit_price_minor,
          taxable_minor: taxable, hsn_sac_code: item.hsn_sac_code,
          tax_rate_basis_points: item.tax_rate_basis_points,
          cess_rate_basis_points: item.cess_rate_basis_points,
          tax_components: tax.components.transform_keys(&:to_s),
          item_snapshot: {
            "id" => item.id, "code" => item.code, "name" => item.name,
            "itemType" => item.item_type, "hsnSacCode" => item.hsn_sac_code,
            "unitOfMeasure" => item.unit_of_measure,
            "incomeAccountCode" => item.income_account_code,
            "taxRateBasisPoints" => item.tax_rate_basis_points,
            "cessRateBasisPoints" => item.cess_rate_basis_points
          }
        }
      end
    end

    def party_snapshot(party, registration)
      {
        "id" => party.id, "partyNumber" => party.party_number, "name" => party.name,
        "email" => party.email, "phone" => party.phone,
        "addressLine1" => party.address_line1, "addressLine2" => party.address_line2,
        "city" => party.city, "postalCode" => party.postal_code,
        "stateCode" => party.state_code, "countryCode" => party.country_code,
        "gstin" => registration.identifier, "gstinStateCode" => registration.state_code,
        "gstinValidFrom" => registration.valid_from.iso8601,
        "gstinValidTo" => registration.valid_to&.iso8601
      }.compact
    end

    def registration_snapshot(registration, entity, office)
      {
        "id" => registration.id, "kind" => registration.kind,
        "identifier" => registration.identifier, "jurisdiction" => registration.jurisdiction,
        "stateCode" => registration.state_code,
        "validFrom" => registration.valid_from.iso8601,
        "validTo" => registration.valid_to&.iso8601,
        "legalName" => entity.legal_name, "officeName" => office.name,
        "addressLine1" => office.address_line1, "addressLine2" => office.address_line2,
        "city" => office.city, "postalCode" => office.postal_code,
        "countryCode" => office.country_code
      }.compact
    end

    def parse_date!(value, label)
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    rescue Date::Error
      raise InvalidInvoice, "#{label} must be a valid ISO date"
    end

    def decimal!(value, label)
      Documents::DecimalInput.parse!(value, label: label, scale: 6, error_class: InvalidInvoice)
    end

    def money_minor!(value, label)
      decimal = Documents::DecimalInput.parse!(
        value, label: label, scale: 2, minimum: 0, error_class: InvalidInvoice
      )
      scaled = decimal * 100
      scaled.to_i
    end

    def value(hash, key) = hash[key] || hash[key.to_s]
  end
end
