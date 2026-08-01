# frozen_string_literal: true

module Settlements
  module BuildDraft
    TYPES = {
      "RC" => { role: "customer", account_code: "1200", label: "receipt" },
      "PY" => { role: "vendor", account_code: "2000", label: "payment" }
    }.freeze
    CASH_ACCOUNT_CODES = %w[1000 1010].freeze
    # Where withheld TDS lands. A vendor payment with withholding posts a 3-way split:
    # Dr AP (gross) / Cr Bank (net) / Cr TDS Payable (tds).
    TDS_PAYABLE_ACCOUNT_CODE = "2110"

    module_function

    def call(tenant:, doc_type:, document_date:, bank_account_code:, allocations:, narration: nil,
             tds_section: nil)
      type_config = TYPES[doc_type.to_s]
      raise InvalidSettlement, "choose customer receipt or vendor payment" unless type_config
      date = parse_date!(document_date)
      entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      office = Office.find_by!(tenant_id: tenant.id, entity_id: entity.id, code: "PRIMARY")
      type = DocumentType.where(tenant_id: tenant.id, active: true).find_by!(
        code: doc_type, posting_rule: "settlement"
      )
      currency = tenant.functional_currency
      exponent = CurrencyProfile.exponent_for!(currency)

      bank_code = bank_account_code.to_s.strip
      unless CASH_ACCOUNT_CODES.include?(bank_code) &&
             Account.active.where(tenant_id: tenant.id, code: bank_code, account_type: "asset").exists?
        raise InvalidSettlement, "choose an active cash or bank account"
      end

      normalized = normalize_allocations!(
        tenant: tenant, type_config: type_config, date: date, raw_allocations: allocations
      )
      party_ids = normalized.map { |allocation| allocation.fetch(:target).party_id }.uniq
      raise InvalidSettlement, "all allocations must belong to one counterparty" unless party_ids.one?

      party = Party.where(tenant_id: tenant.id).find(party_ids.first)
      total = normalized.sum { |allocation| allocation.fetch(:amount_minor) }
      direction = doc_type == "RC" ? 1 : -1
      # Withholding applies only to vendor payments, and only when a section resolves
      # (explicit, or the vendor's default) and the amount actually crosses the threshold.
      withholding = withholding_for(
        tenant: tenant, entity: entity, party: party, doc_type: doc_type,
        section: tds_section, date: date, gross: total
      )
      tds_minor = withholding ? withholding.fetch("tds_minor") : 0

      Document.transaction do
        document = Document.create!(
          tenant_id: tenant.id, entity_id: entity.id, office_id: office.id,
          doc_type: type.code, document_type: type,
          fiscal_year: Documents.fiscal_year(date, variant: entity.fiscal_year_variant),
          document_date: date, posting_date: date, due_date: date,
          narration: narration, state: "draft", party: party,
          currency: currency, minor_unit_exponent: exponent,
          subtotal_minor: total, tax_minor: 0, total_minor: total,
          party_snapshot: settlement_party_snapshot(party, normalized.first.fetch(:target))
        )
        document.document_lines.create!(
          tenant_id: tenant.id, line_no: 1, account_code: bank_code,
          amount_minor: direction * (total - tds_minor), currency: currency,
          minor_unit_exponent: exponent, narration: narration,
          extra: { "settlementKind" => type_config.fetch(:label) }
        )
        if withholding
          document.document_lines.create!(
            tenant_id: tenant.id, line_no: 2, account_code: TDS_PAYABLE_ACCOUNT_CODE,
            amount_minor: direction * tds_minor, currency: currency,
            minor_unit_exponent: exponent, narration: "TDS #{withholding.fetch('section')}",
            extra: { "tds" => withholding }
          )
        end
        normalized.each_with_index do |allocation, index|
          target = allocation.fetch(:target)
          document.document_allocations.create!(
            tenant_id: tenant.id, line_no: index + 1,
            target_entry_line_id: target.id,
            target_source_event_id: target.source_event_id,
            target_ledger_id: target.ledger_id,
            target_line_no: target.line_no,
            amount_minor: allocation.fetch(:amount_minor),
            clearing_mode: allocation.fetch(:clearing_mode),
            target_snapshot: target_snapshot(target)
          )
        end
        Posting::Rules::Settlement.validate_document!(document)
        document
      end
    rescue ActiveRecord::RecordNotFound => e
      raise InvalidSettlement, "a settlement master or open item is unavailable: #{e.model}"
    end

    def normalize_allocations!(tenant:, type_config:, date:, raw_allocations:)
      rows = Array(raw_allocations).reject do |allocation|
        value(allocation, :target_entry_line_id).blank? || value(allocation, :amount).blank?
      end
      raise InvalidSettlement, "add at least one allocation" if rows.empty?

      ids = rows.map { |allocation| value(allocation, :target_entry_line_id).to_s }
      raise InvalidSettlement, "each open item may be allocated only once" unless ids.uniq.size == ids.size

      targets = EntryLine.where(tenant_id: tenant.id, id: ids).includes(:amounts, entry: :document).index_by do |line|
        line.id.to_s
      end
      rows.map do |allocation|
        target = targets[value(allocation, :target_entry_line_id).to_s]
        validate_target!(target, type_config, date)
        amount_minor = money_minor!(value(allocation, :amount), "allocation for #{target.assignment}")
        outstanding = Posting::Clearing.open_amount(target)
        unless amount_minor.positive? && amount_minor <= outstanding
          raise InvalidSettlement,
            "allocation for #{target.assignment} must be positive and no more than #{money_label(outstanding)}"
        end
        mode = value(allocation, :clearing_mode).presence || "partial"
        unless DocumentAllocation::MODES.include?(mode)
          raise InvalidSettlement, "choose partial or residual clearing for #{target.assignment}"
        end

        { target: target, amount_minor: amount_minor, clearing_mode: mode }
      end
    end

    def validate_target!(target, type_config, date)
      unless eligible_target?(target, type_config)
        raise InvalidSettlement, "a selected item is not an eligible open #{type_config.fetch(:role)} item"
      end
      if target.entry.document_date > date
        raise InvalidSettlement, "settlement date cannot precede #{target.assignment}"
      end
    end

    def eligible_target?(target, type_config)
      return false unless target&.open_item? && target.cleared_on.nil? && target.source_event_id.present? &&
                          target.account_code == type_config.fetch(:account_code) &&
                          target.party_role == type_config.fetch(:role) && target.party_id.present?

      amount = target.amounts.find { |candidate| candidate.slot_role == "transaction" }&.amount_minor.to_i
      type_config.fetch(:role) == "customer" ? amount.positive? : amount.negative?
    end

    # Returns a frozen withholding snapshot (string-keyed, stored on the TDS line's extra and
    # later persisted as a TdsDeduction), or nil when no TDS applies. Matches Bahi's oracle:
    # the base is the GROSS amount being paid (not ex-GST). §206AA (no PAN) is handled by the
    # kernel; the PAN is derived from the vendor's in-force GSTIN.
    def withholding_for(tenant:, entity:, party:, doc_type:, section:, date:, gross:)
      return nil unless doc_type == "PY"

      resolved_section = section.presence || party.default_tds_section
      return nil if resolved_section.blank?

      pan = vendor_pan(party, date)
      fiscal_year = Documents.fiscal_year(date, variant: entity.fiscal_year_variant)
      prior = TdsDeduction.for_tenant(tenant.id)
        .where(party_id: party.id, section: resolved_section, fiscal_year: fiscal_year)
        .sum(:taxable_minor)
      result = Taxes::India::Tds::Deduction.compute(
        section: resolved_section, on: date, amount_minor: gross, pan: pan, fy_paid_to_date_minor: prior
      )
      return nil unless result.applied && result.tds_minor.positive?

      {
        "section" => resolved_section, "rate_basis_points" => result.rate_basis_points,
        "taxable_minor" => gross, "tds_minor" => result.tds_minor,
        "deductee_pan" => pan, "deductee_name_snapshot" => party.name,
        "party_id" => party.id, "fiscal_year" => fiscal_year,
        "quarter" => TdsDeduction.india_quarter(date)
      }
    rescue Taxes::India::Tds::UnknownSection, Taxes::India::Tds::InvalidInput => e
      raise InvalidSettlement, "TDS section #{section.presence || party.default_tds_section} is unavailable: #{e.message}"
    end

    def vendor_pan(party, date)
      gstin = party.party_tax_registrations.in_force_on(date).find_by(kind: "GSTIN")&.identifier
      gstin[2, 10] if gstin && gstin.length >= 12
    end

    def settlement_party_snapshot(party, target)
      frozen = target.extra.to_h.fetch("partySnapshot", {})
      frozen.presence || {
        "id" => party.id, "partyNumber" => party.party_number, "name" => party.name,
        "email" => party.email, "phone" => party.phone
      }.compact
    end

    def target_snapshot(target)
      source = target.entry.document
      {
        "entryLineId" => target.id,
        "sourceEventId" => target.source_event_id,
        "ledgerId" => target.ledger_id,
        "lineNo" => target.line_no,
        "accountCode" => target.account_code,
        "partyId" => target.party_id,
        "partyRole" => target.party_role,
        "assignment" => target.assignment,
        "baselineDate" => target.baseline_date&.iso8601,
        "dueDate" => target.due_date&.iso8601,
        "outstandingMinor" => Posting::Clearing.open_amount(target),
        "sourceDocumentId" => source&.id,
        "sourceDocumentNumber" => source&.document_number
      }.compact
    end

    def parse_date!(value)
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    rescue Date::Error
      raise InvalidSettlement, "settlement date must be a valid ISO date"
    end

    def money_minor!(value, label)
      decimal = BigDecimal(value.to_s)
      scaled = decimal * 100
      unless decimal.positive? && scaled.frac.zero?
        raise InvalidSettlement, "#{label} must be positive with no more than two decimal places"
      end

      scaled.to_i
    rescue ArgumentError
      raise InvalidSettlement, "#{label} must be a valid amount"
    end

    def money_label(amount_minor)
      format("%.2f", amount_minor.to_i / 100.0)
    end

    def value(hash, key) = hash[key] || hash[key.to_s]
  end
end
