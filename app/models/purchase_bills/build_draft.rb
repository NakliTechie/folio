# frozen_string_literal: true

module PurchaseBills
  # Resolves the buyer, vendor, item, and GST masters once and freezes the complete bill basis.
  # The supplier invoice number remains the external reference; Folio allocates a separate PB number.
  module BuildDraft
    module_function

    def call(tenant:, party_id:, tax_registration_id:, document_date:, due_date:,
             place_of_supply_state_code: nil, external_reference:, lines:, narration: nil,
             tds_section: nil, place_of_supply_override_reason: nil, actor: nil,
             purchase_order_id: nil)
      bill_date = parse_date!(document_date, "supplier invoice date")
      payment_due = parse_date!(due_date, "due date")
      raise InvalidBill, "due date cannot be before the supplier invoice date" if payment_due < bill_date

      supplier_reference = external_reference.to_s.strip.upcase
      if supplier_reference.blank? || supplier_reference.length > 100
        raise InvalidBill, "supplier invoice number is required and may be no more than 100 characters"
      end

      entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      unless entity.jurisdiction_profile == "IN" && tenant.functional_currency == "INR"
        raise InvalidBill, "purchase bills currently require an India/INR accounting profile"
      end
      office = Office.find_by!(tenant_id: tenant.id, entity_id: entity.id, code: "PRIMARY")
      unless office.statutory_address_complete? && office.country_code == "IN"
        raise InvalidBill, "complete India company details are required before recording a purchase bill"
      end

      type = DocumentType.where(tenant_id: tenant.id, active: true).find_by!(
        code: "PB", posting_rule: "purchase_bill"
      )
      vendor = Party.active.includes(:party_roles, :party_tax_registrations)
        .where(tenant_id: tenant.id).find(party_id)
      raise InvalidBill, "the selected party is not a vendor" unless vendor.role_codes.include?("vendor")
      profile = VendorProfile.find_by(tenant_id: tenant.id, party_id: vendor.id)
      raise InvalidBill, "this vendor is on posting hold" if profile&.posting_hold?
      unless vendor.statutory_address_complete? && vendor.country_code == "IN"
        raise InvalidBill, "the selected vendor needs a complete India billing address"
      end
      if Document.where(
        tenant_id: tenant.id, party_id: vendor.id, doc_type: "PB", external_reference: supplier_reference
      ).exists?
        raise InvalidBill, "this supplier invoice number is already recorded for the vendor"
      end

      vendor_registration = vendor.party_tax_registrations.in_force_on(bill_date)
        .where(kind: "GSTIN").order(valid_from: :desc).first
      raise InvalidBill, "the selected vendor needs a GSTIN in force on the invoice date" unless vendor_registration

      buyer_registration = TaxRegistration.in_force_on(bill_date)
        .joins(:office_tax_registrations)
        .where(
          tenant_id: tenant.id, entity_id: entity.id, id: tax_registration_id, kind: "GSTIN",
          office_tax_registrations: { office_id: office.id, tenant_id: tenant.id }
        ).first
      raise InvalidBill, "the selected buyer GSTIN is unavailable for this office and date" unless buyer_registration
      unless buyer_registration.state_code == office.state_code
        raise InvalidBill, "the buying office state must match the selected buyer GSTIN"
      end
      purchase_order = resolve_purchase_order!(
        tenant: tenant, entity: entity, office: office, vendor: vendor, purchase_order_id: purchase_order_id
      )

      place_state = place_of_supply_state_code.to_s.presence || buyer_registration.state_code
      unless Taxes::India::StateCodes.valid?(place_state)
        raise InvalidBill, "place of supply must be a valid GST state code"
      end
      place_evidence = Taxes::India::PlaceOfSupplyEvidence.build!(
        tenant: tenant, party: vendor, selected_state_code: place_state, actor: actor,
        override_reason: place_of_supply_override_reason,
        default_basis: "buyer_registration", default_state_code: buyer_registration.state_code,
        error_class: InvalidBill
      )

      normalized_lines = normalize_lines!(
        tenant: tenant, entity: entity, vendor_registration: vendor_registration,
        place_state: place_state, raw_lines: lines
      )
      subtotal = normalized_lines.sum { |line| line.fetch(:taxable_minor) }
      breakdown = normalized_lines.each_with_object(Hash.new(0)) do |line, result|
        line.fetch(:tax_components).each { |component, value| result[component] += value }
      end
      tax_total = breakdown.values.sum
      currency = tenant.functional_currency
      exponent = CurrencyProfile.exponent_for!(currency)
      resolved_tds_section = if tds_section.to_s == "none"
        nil
      else
        tds_section.presence || vendor.default_tds_section
      end
      tds_assessment = TdsAssessment.build(
        tenant: tenant,
        entity: entity,
        party: vendor,
        on: bill_date,
        gross_minor: subtotal + tax_total,
        gst_minor: tax_total,
        section: resolved_tds_section
      )

      Document.transaction do
        document = Document.create!(
          tenant_id: tenant.id, entity_id: entity.id, office_id: office.id,
          doc_type: type.code, document_type: type,
          fiscal_year: Documents.fiscal_year(bill_date, variant: entity.fiscal_year_variant),
          document_date: bill_date, posting_date: bill_date, due_date: payment_due,
          external_reference: supplier_reference, narration: narration,
          purchase_order: purchase_order,
          state: "draft", party: vendor, tax_registration: buyer_registration,
          supply_type: "B2B", place_of_supply_state_code: place_state,
          place_of_supply_evidence: place_evidence,
          currency: currency, minor_unit_exponent: exponent,
          subtotal_minor: subtotal, tax_minor: tax_total, total_minor: subtotal + tax_total,
          party_snapshot: party_snapshot(vendor, vendor_registration),
          tax_registration_snapshot: registration_snapshot(buyer_registration, entity, office),
          tax_breakdown: breakdown,
          **tds_assessment
        )
        normalized_lines.each_with_index do |line, index|
          document.document_lines.create!(
            tenant_id: tenant.id, line_no: index + 1,
            account_code: line.fetch(:account_code), amount_minor: line.fetch(:taxable_minor),
            currency: currency, minor_unit_exponent: exponent,
            narration: line.fetch(:name), item_id: line.fetch(:item_id),
            quantity: line.fetch(:quantity), unit_price_minor: line.fetch(:unit_price_minor),
            taxable_minor: line.fetch(:taxable_minor), hsn_sac_code: line.fetch(:hsn_sac_code),
            tax_rate_basis_points: line.fetch(:tax_rate_basis_points),
            cess_rate_basis_points: line.fetch(:cess_rate_basis_points),
            tax_components: line.fetch(:tax_components), item_snapshot: line.fetch(:item_snapshot)
          )
        end
        Procurement::MatchBill.call!(document: document, purchase_order: purchase_order) if purchase_order
        Posting::Rules::PurchaseBill.validate_document!(document)
        document
      end
    rescue ActiveRecord::RecordNotFound => e
      raise InvalidBill, "a purchase-bill master is unavailable: #{e.model}"
    rescue ActiveRecord::RecordNotUnique
      raise InvalidBill, "this supplier invoice number is already recorded for the vendor"
    rescue Procurement::InvalidProcurement => e
      raise InvalidBill, e.message
    end

    def resolve_purchase_order!(tenant:, entity:, office:, vendor:, purchase_order_id:)
      return if purchase_order_id.blank?

      order = PurchaseOrder.where(
        tenant_id: tenant.id, entity_id: entity.id, office_id: office.id
      ).find(purchase_order_id)
      raise InvalidBill, "the purchase order belongs to another vendor" unless order.vendor.id == vendor.id
      unless %w[approved partially_received received closed].include?(order.status)
        raise InvalidBill, "only a released purchase order can be matched to a bill"
      end

      order
    end

    def normalize_lines!(tenant:, entity:, vendor_registration:, place_state:, raw_lines:)
      rows = Array(raw_lines).reject { |line| value(line, :item_id).blank? }
      raise InvalidBill, "add at least one purchase-bill line" if rows.empty?

      rows.map do |line|
        item = Item.active.where(tenant_id: tenant.id).find(value(line, :item_id))
        quantity = decimal!(value(line, :quantity), "quantity for #{item.code}")
        raise InvalidBill, "quantity for #{item.code} must be positive" unless quantity.positive?

        unit_price_minor = money_minor!(value(line, :unit_price), "unit price for #{item.code}")
        taxable = (quantity * unit_price_minor).round(0, BigDecimal::ROUND_HALF_UP).to_i
        raise InvalidBill, "taxable value for #{item.code} must be positive" unless taxable.positive?

        tax = Taxes.calculate(
          entity: entity, taxable_minor: taxable,
          rate_basis_points: item.tax_rate_basis_points,
          cess_rate_basis_points: item.cess_rate_basis_points,
          supplier_state_code: vendor_registration.state_code,
          place_of_supply_state_code: place_state
        )
        {
          item_id: item.id, account_code: item.expense_account_code,
          name: item.name, quantity: quantity, unit_price_minor: unit_price_minor,
          taxable_minor: taxable, hsn_sac_code: item.hsn_sac_code,
          tax_rate_basis_points: item.tax_rate_basis_points,
          cess_rate_basis_points: item.cess_rate_basis_points,
          tax_components: tax.components.transform_keys(&:to_s),
          item_snapshot: {
            "id" => item.id, "code" => item.code, "name" => item.name,
            "itemType" => item.item_type, "hsnSacCode" => item.hsn_sac_code,
            "unitOfMeasure" => item.unit_of_measure,
            "expenseAccountCode" => item.expense_account_code,
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
      raise InvalidBill, "#{label} must be a valid ISO date"
    end

    def decimal!(value, label)
      Documents::DecimalInput.parse!(value, label: label, scale: 6, error_class: InvalidBill)
    end

    def money_minor!(value, label)
      decimal = Documents::DecimalInput.parse!(
        value, label: label, scale: 2, minimum: 0, error_class: InvalidBill
      )
      scaled = decimal * 100
      scaled.to_i
    end

    def value(hash, key) = hash[key] || hash[key.to_s]
  end
end
