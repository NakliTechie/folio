# frozen_string_literal: true

require "csv"

module Banking
  module ImportStatement
    HEADERS = %w[booking_date value_date amount reference description counterparty].freeze
    MAX_ROWS = 10_000
    MAX_BYTES = 5.megabytes

    module_function

    def call(tenant:, actor:, bank_account_code:, currency:, opening_balance:, closing_balance:,
             file_name:, csv_text:)
      code = bank_account_code.to_s.strip
      selected_currency = currency.to_s.upcase
      account = Account.active.where(
        tenant_id: tenant.id, code: code, account_type: "asset", monetary: true
      ).first
      raise InvalidStatement, "choose an active monetary asset account" unless account
      raise InvalidStatement, "bank statement exceeds 5 MB" if csv_text.to_s.bytesize > MAX_BYTES
      exponent = CurrencyProfile.exponent_for!(selected_currency)
      rows = parse_rows(csv_text, selected_currency, exponent)
      entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      office = Office.find_by!(tenant_id: tenant.id, entity_id: entity.id, code: "PRIMARY")
      source_hash = Digest::SHA256.hexdigest(csv_text.to_s.b)

      opening_minor = money_minor(opening_balance, exponent, "opening balance")
      closing_minor = money_minor(closing_balance, exponent, "closing balance")
      existing = BankStatementImport.find_by(
        tenant_id: tenant.id, bank_account_code: code, source_sha256: source_hash
      )
      if existing
        unless existing.currency == selected_currency &&
            existing.opening_balance_minor == opening_minor &&
            existing.closing_balance_minor == closing_minor
          raise InvalidStatement, "this source file was already imported with different statement metadata"
        end
        return existing
      end

      BankStatementImport.transaction do
        event = DomainEvents::Record.call(
          tenant_id: tenant.id, office_id: office.id, kind: "bank_statement.imported",
          actor: "u:#{actor.id}", actor_user_id: actor.id, ref: source_hash,
          payload: {
            "bankAccountCode" => code, "currency" => selected_currency,
            "fileName" => normalized_file_name(file_name), "sourceSha256" => source_hash,
            "statementFrom" => rows.pluck(:booking_date).min.iso8601,
            "statementTo" => rows.pluck(:booking_date).max.iso8601,
            "rowCount" => rows.size
          }
        )
        statement = BankStatementImport.create!(
          tenant_id: tenant.id, entity: entity, office: office, created_by: actor,
          created_domain_event: event, bank_account_code: code, currency: selected_currency,
          file_name: normalized_file_name(file_name),
          source_sha256: source_hash,
          statement_from: rows.map { |row| row.fetch(:booking_date) }.min,
          statement_to: rows.map { |row| row.fetch(:booking_date) }.max,
          opening_balance_minor: opening_minor,
          closing_balance_minor: closing_minor,
          row_count: rows.size
        )
        rows.each_with_index do |row, index|
          statement.bank_statement_lines.create!(
            row.merge(tenant_id: tenant.id, line_no: index + 1)
          )
        end
        statement
      end
    rescue CSV::MalformedCSVError, ArgumentError => e
      raise if e.is_a?(InvalidStatement)

      raise InvalidStatement, "bank statement CSV is malformed: #{e.message}"
    rescue ActiveRecord::RecordNotUnique
      BankStatementImport.find_by!(
        tenant_id: tenant.id, bank_account_code: code, source_sha256: source_hash
      )
    end

    def parse_rows(text, currency, exponent)
      table = CSV.parse(
        text.to_s, headers: true,
        header_converters: ->(header) { header.to_s.strip.downcase }
      )
      duplicates = table.headers.compact.tally.select { |_header, count| count > 1 }.keys
      raise InvalidStatement, "bank statement has duplicate columns: #{duplicates.join(', ')}" if duplicates.any?
      missing = HEADERS - table.headers.compact
      raise InvalidStatement, "bank statement is missing columns: #{missing.join(', ')}" if missing.any?
      unknown = table.headers.compact - HEADERS
      raise InvalidStatement, "bank statement has unknown columns: #{unknown.join(', ')}" if unknown.any?
      raise InvalidStatement, "bank statement is empty" if table.empty?
      raise InvalidStatement, "bank statement exceeds #{MAX_ROWS} rows" if table.size > MAX_ROWS

      table.map.with_index do |row, index|
        booking = parse_date(row["booking_date"], index)
        {
          booking_date: booking,
          value_date: row["value_date"].present? ? parse_date(row["value_date"], index) : booking,
          amount_minor: money_minor(row["amount"], exponent, "amount on row #{index + 2}"),
          currency: currency,
          bank_reference: row["reference"].to_s.strip.presence,
          description: row["description"].to_s.strip.presence || "Bank transaction",
          counterparty: row["counterparty"].to_s.strip.presence
        }
      end
    end

    def money_minor(value, exponent, label)
      decimal = Documents::DecimalInput.parse!(
        value, label: label, scale: exponent, error_class: InvalidStatement
      )
      minor = (decimal * (10**exponent)).to_i
      raise InvalidStatement, "#{label} cannot be zero" if label.start_with?("amount") && minor.zero?

      minor
    end

    def parse_date(value, index)
      Date.iso8601(value.to_s)
    rescue Date::Error
      raise InvalidStatement, "booking/value date on row #{index + 2} must be ISO YYYY-MM-DD"
    end

    def normalized_file_name(value)
      name = File.basename(value.to_s.strip)
      name.presence && name != "." ? name : "statement.csv"
    end
  end
end
