# frozen_string_literal: true

module Documents
  # One draft-construction boundary for browser and API callers. It resolves tenant-owned
  # configuration, parses values strictly, and stores a complete fiscal identity.
  module BuildDraft
    module_function

    def call(tenant:, doc_type:, document_date:, posting_date:, narration:, lines:, fiscal_year: nil)
      document_on = parse_date!(document_date, "document date")
      posting_on = parse_date!(posting_date, "posting date")
      entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      office = Office.find_by!(tenant_id: tenant.id, entity_id: entity.id, code: "PRIMARY")
      type = DocumentType.where(tenant_id: tenant.id, active: true).find_by!(code: doc_type)
      resolved_fiscal_year = Documents.fiscal_year(posting_on, variant: entity.fiscal_year_variant)
      assert_fiscal_year!(fiscal_year, resolved_fiscal_year)
      normalized_lines = normalize_lines!(tenant, lines)

      Document.transaction do
        document = Document.create!(
          tenant_id: tenant.id,
          entity_id: entity.id,
          office_id: office.id,
          doc_type: type.code,
          document_type: type,
          fiscal_year: resolved_fiscal_year,
          document_date: document_on,
          posting_date: posting_on,
          narration: narration,
          state: "draft"
        )
        normalized_lines.each_with_index do |line, index|
          document.document_lines.create!(
            tenant_id: tenant.id,
            line_no: index + 1,
            account_code: line.fetch(:account_code),
            amount_minor: line.fetch(:amount_minor),
            currency: line.fetch(:currency),
            minor_unit_exponent: line.fetch(:minor_unit_exponent),
            narration: line[:narration] || narration,
            extra: line[:extra]
          )
        end
        document
      end
    end

    def normalize_lines!(tenant, lines)
      rows = Array(lines)
      raise InvalidDocument, "a document needs at least two non-zero lines" if rows.size < 2

      expected_currency = tenant.functional_currency
      expected_exponent = CurrencyProfile.exponent_for!(expected_currency)
      active_codes = Account.active.where(tenant_id: tenant.id,
        code: rows.map { |line| value(line, :account_code).to_s }).pluck(:code)

      rows.map do |line|
        code = value(line, :account_code).to_s.strip
        raise InvalidDocument, "account #{code.presence || "(blank)"} is unavailable" unless active_codes.include?(code)

        amount = strict_integer!(value(line, :amount_minor), "amount_minor for #{code}")
        raise InvalidDocument, "amount_minor for #{code} must be non-zero" if amount.zero?

        currency = (value(line, :currency).presence || expected_currency).to_s.upcase
        exponent = if value(line, :minor_unit_exponent).present?
          strict_integer!(value(line, :minor_unit_exponent), "minor_unit_exponent for #{code}")
        else
          expected_exponent
        end
        unless currency == expected_currency && exponent == expected_exponent
          raise InvalidDocument,
            "#{code} must use #{expected_currency} with minor-unit exponent #{expected_exponent}"
        end

        {
          account_code: code,
          amount_minor: amount,
          currency: currency,
          minor_unit_exponent: exponent,
          narration: value(line, :narration),
          extra: value(line, :extra)
        }
      end
    end

    def parse_date!(value, label)
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    rescue Date::Error
      raise InvalidDocument, "#{label} must be a valid ISO date"
    end

    def assert_fiscal_year!(supplied, resolved)
      return if supplied.blank?

      parsed = strict_integer!(supplied, "fiscal_year")
      return if parsed == resolved

      raise InvalidDocument, "fiscal_year #{parsed} does not match posting date (expected #{resolved})"
    end

    def strict_integer!(value, label)
      return value if value.is_a?(Integer)
      return Integer(value, 10) if value.is_a?(String) && value.match?(/\A-?\d+\z/)

      raise InvalidDocument, "#{label} must be an integer"
    rescue ArgumentError
      raise InvalidDocument, "#{label} must be an integer"
    end

    def value(line, key)
      line[key] || line[key.to_s]
    end
  end
end
