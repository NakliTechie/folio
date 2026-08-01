# frozen_string_literal: true

require "csv"
require "digest"
require "json"
require "stringio"
require "zip"

module SapBusinessOne
  class DtwExport
    Result = Data.define(:bytes, :filename, :manifest)
    SCOPES = %w[entity office group].freeze
    FIXED_ZIP_TIME = Time.utc(1980, 1, 1).freeze
    ACCOUNT_GROUPS = {
      "asset" => 1, "liability" => 2, "equity" => 3, "income" => 4, "expense" => 6
    }.freeze

    def self.call(...) = new(...).call

    def initialize(tenant:, scope:, from_date:, to_date:, entity_id: nil, office_id: nil, group_id: nil)
      @tenant = tenant
      @scope = scope.to_s
      @from_date = parse_date(from_date, :from_date)
      @to_date = parse_date(to_date, :to_date)
      @entity_id = entity_id
      @office_id = office_id
      @group_id = group_id
    end

    def call
      validate_request!
      assert_chain!
      records = journal_records
      files = data_files(records)
      manifest = build_manifest(files, records)
      files["FOLIO-MANIFEST.json"] = JSON.pretty_generate(manifest) + "\n"
      Result.new(
        bytes: zip(files), filename: filename, manifest: manifest
      )
    end

    private

    attr_reader :tenant, :scope, :from_date, :to_date, :entity_id, :office_id, :group_id

    def validate_request!
      raise InvalidExport, "Export scope must be entity, office, or group" unless SCOPES.include?(scope)
      raise InvalidExport, "From date must be on or before the to date" if from_date > to_date

      scope_context
    end

    def assert_chain!
      result = LedgerEvent.verify_chain(tenant.id)
      return if result.fetch(:ok)

      raise InvalidExport,
        "Ledger chain verification failed at sequence #{result[:broken_at]}; export was not created"
    end

    def scope_context
      @scope_context ||= case scope
      when "entity"
        entity = Entity.where(tenant_id: tenant.id).find(entity_id)
        { code: entity.code, currency: entity.functional_currency, entity_ids: [ entity.id ], layers: [ "00" ] }
      when "office"
        office = Office.where(tenant_id: tenant.id).includes(:entity).find(office_id)
        { code: office.code, currency: office.entity.functional_currency,
          entity_ids: [ office.entity_id ], office_id: office.id, layers: [ "00" ] }
      when "group"
        group = ConsolidationGroup.where(tenant_id: tenant.id).includes(:consolidation_group_members).find(group_id)
        members = group.consolidation_group_members.select { |member| member.effective_on?(to_date) }
        raise InvalidExport, "Consolidation group has no effective members on the export date" if members.empty?

        entities = Entity.where(tenant_id: tenant.id, id: members.map(&:entity_id)).to_a
        unless entities.all? { |entity| entity.functional_currency == group.presentation_currency }
          raise InvalidExport, "Cross-currency DTW export needs an approved group translation policy"
        end
        { code: group.code, currency: group.presentation_currency,
          entity_ids: entities.map(&:id), members: members.index_by(&:entity_id), layers: %w[00 EL] }
      end
    end

    def scoped_lines
      context = scope_context
      relation = EntryLine.includes(
        :amounts, :ledger, :party, :profit_center, :controlling_segment,
        entry: [ :document ]
      ).joins(:entry).where(
        tenant_id: tenant.id, entity_id: context.fetch(:entity_ids), line_class: "real",
        posting_layer: context.fetch(:layers),
        ledger_id: Ledger.where(tenant_id: tenant.id, posts_to_gl: true),
        entries: { posting_date: from_date..to_date }
      )
      relation = relation.where(office_id: context.fetch(:office_id)) if context[:office_id]
      lines = relation.order("entries.posting_date", "entries.id", :ledger_id, :line_no, :id).to_a
      return lines unless scope == "group"

      lines.select do |line|
        member = context.fetch(:members)[line.entity_id]
        member&.effective_on?(line.entry.posting_date)
      end
    end

    def journal_records
      scoped_lines.group_by { |line| [ line.entry_id, line.ledger_id ] }.map do |(_entry_id, _ledger_id), lines|
        amounts = lines.map { |line| [ line, reporting_amount(line) ] }
        exponents = amounts.map { |_line, amount| amount.minor_unit_exponent }.uniq
        raise InvalidExport, "One SAP journal cannot mix currency exponents" unless exponents.one?
        total = amounts.sum { |_line, amount| amount.amount_minor }
        unless total.zero?
          raise InvalidExport,
            "Filtered SAP journal for Folio entry #{lines.first.entry_id} is unbalanced by #{total} minor units"
        end
        { entry: lines.first.entry, ledger: lines.first.ledger, lines: amounts,
          exponent: exponents.sole }
      end
    end

    def reporting_amount(line)
      currency = scope_context.fetch(:currency)
      roles = scope == "group" ? %w[group functional transaction] : %w[functional transaction]
      amount = roles.filter_map do |role|
        line.amounts.find { |candidate| candidate.slot_role == role && candidate.currency == currency }
      end.first
      return amount if amount

      raise InvalidExport,
        "Entry #{line.entry_id} line #{line.line_no} has no #{currency} amount for the #{scope} export"
    end

    def data_files(records)
      {
        "OACT - ChartOfAccounts.csv" => accounts_csv,
        "OCRD - BusinessPartners.csv" => business_partners_csv,
        "OJDT - JournalEntries.csv" => journal_headers_csv(records),
        "JDT1 - JournalEntries_Lines.csv" => journal_lines_csv(records),
        "FOLIO - AccountCrosswalk.csv" => account_crosswalk_csv,
        "FOLIO - BusinessPartnerCrosswalk.csv" => business_partner_crosswalk_csv,
        "FOLIO - SourceEvents.csv" => source_events_csv(records)
      }
    end

    def accounts
      @accounts ||= Account.where(tenant_id: tenant.id).in_code_order.to_a
    end

    def parties
      @parties ||= Party.includes(:party_roles).where(tenant_id: tenant.id).order(:party_number).to_a
    end

    def partner_rows
      @partner_rows ||= parties.flat_map do |party|
        party.role_codes.filter_map do |role|
          next unless %w[customer vendor].include?(role)

          { party: party, role: role, sap_code: "#{role == 'customer' ? 'C' : 'V'}#{party.id}",
            card_type: role == "customer" ? "C" : "S" }
        end
      end
    end

    def accounts_csv
      rows = accounts.map do |account|
        [ account.code, csv_text(account.name), "tYES", ACCOUNT_GROUPS.fetch(account.account_type),
          scope_context.fetch(:currency), account.active? ? "tYES" : "tNO" ]
      end
      csv(%w[AcctCode AcctName Postable GroupMask ActCurr ActiveAccount], rows)
    end

    def account_crosswalk_csv
      rows = accounts.map do |account|
        [ account.code, account.code, account.account_type, ACCOUNT_GROUPS.fetch(account.account_type) ]
      end
      csv(%w[FolioAccountCode SAPAccountCode FolioAccountType SAPGroupMask], rows)
    end

    def business_partners_csv
      rows = partner_rows.map do |row|
        party = row.fetch(:party)
        [ row.fetch(:sap_code), csv_text(party.name), row.fetch(:card_type),
          scope_context.fetch(:currency), party.active? ? "tYES" : "tNO" ]
      end
      csv(%w[CardCode CardName CardType Currency Valid], rows)
    end

    def business_partner_crosswalk_csv
      rows = partner_rows.map do |row|
        party = row.fetch(:party)
        [ party.id, party.party_number, row.fetch(:role), row.fetch(:sap_code) ]
      end
      csv(%w[FolioPartyId FolioPartyNumber FolioRole SAPCardCode], rows)
    end

    def journal_headers_csv(records)
      rows = records.each_with_index.map do |record, index|
        entry = record.fetch(:entry)
        document = entry.document
        [ index + 1, sap_date(entry.posting_date), sap_date(entry.document_date),
          sap_date(entry.document_date), csv_text(document&.narration || "Folio entry #{entry.id}"),
          csv_text(document&.document_number || "FOLIO-#{entry.id}"), "FOLIO" ]
      end
      csv(%w[RecordKey ReferenceDate DueDate TaxDate Memo Reference TransactionCode], rows)
    end

    def journal_lines_csv(records)
      rows = records.each_with_index.flat_map do |record, record_index|
        record.fetch(:lines).each_with_index.map do |(line, amount), line_index|
          value = decimal_amount(amount.amount_minor, amount.minor_unit_exponent)
          partner = partner_rows.find do |row|
            row.fetch(:party).id == line.party_id && row.fetch(:role) == line.party_role
          end
          [ record_index + 1, line_index, line.account_code, partner&.fetch(:sap_code) || line.account_code,
            amount.amount_minor.positive? ? value : decimal_amount(0, amount.minor_unit_exponent),
            amount.amount_minor.negative? ? decimal_amount(-amount.amount_minor, amount.minor_unit_exponent) :
              decimal_amount(0, amount.minor_unit_exponent),
            csv_text(line.assignment || "Folio line #{line.line_no}"),
            line.profit_center&.code, line.controlling_segment&.code,
            Office.find_by(id: line.office_id, tenant_id: tenant.id)&.code ]
        end
      end
      csv(%w[RecordKey LineNum AccountCode ShortName Debit Credit LineMemo ProfitCode OcrCode2 OcrCode3], rows)
    end

    def source_events_csv(records)
      events = LedgerEvent.where(id: records.map { |record| record.fetch(:entry).ledger_event_id })
        .index_by(&:id)
      rows = records.each_with_index.map do |record, index|
        entry = record.fetch(:entry)
        event = events.fetch(entry.ledger_event_id)
        [ index + 1, entry.id, record.fetch(:ledger).code, event.seq, event.hash_hex,
          event.prev_hash, event.hash_version, event.actor_user_id ]
      end
      csv(%w[SAPRecordKey FolioEntryId FolioLedgerCode LedgerEventSeq LedgerEventHash
        LedgerEventPrevHash HashVersion ActorUserId], rows)
    end

    def build_manifest(files, records)
      debit_minor = records.sum do |record|
        record.fetch(:lines).sum { |_line, amount| [ amount.amount_minor, 0 ].max }
      end
      head = LedgerEvent.for_tenant(tenant.id).in_order.last
      {
        "format" => "folio-sap-business-one-dtw",
        "formatVersion" => 1,
        "target" => "SAP Business One 10.0 DTW",
        "scope" => scope,
        "scopeCode" => scope_context.fetch(:code),
        "currency" => scope_context.fetch(:currency),
        "fromDate" => from_date.iso8601,
        "toDate" => to_date.iso8601,
        "journalCount" => records.size,
        "lineCount" => records.sum { |record| record.fetch(:lines).size },
        "debitMinor" => debit_minor,
        "creditMinor" => debit_minor,
        "ledgerChainHead" => head && { "seq" => head.seq, "hash" => head.hash_hex },
        "files" => files.sort.to_h do |name, data|
          [ name, { "sha256" => Digest::SHA256.hexdigest(data), "bytes" => data.bytesize } ]
        end,
        "importNote" => "Validate these files against templates generated by the target SAP B1 DTW version before import."
      }
    end

    def filename
      code = scope_context.fetch(:code).to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|\z-/, "")
      "folio-sap-b1-dtw-#{scope}-#{code}-#{from_date}-#{to_date}.zip"
    end

    def zip(files)
      Zip::OutputStream.write_buffer do |archive|
        files.sort.each do |name, data|
          entry = Zip::Entry.new("", name)
          entry.time = FIXED_ZIP_TIME
          entry.unix_perms = 0o644
          archive.put_next_entry(entry)
          archive.write(data)
        end
      end.string
    end

    def csv(headers, rows)
      CSV.generate(row_sep: "\r\n", force_quotes: true) do |output|
        output << headers
        rows.each { |row| output << row }
      end
    end

    def csv_text(value)
      text = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
        .delete("\u0000").gsub(/[\r\n]+/, " ").strip
      text.match?(/\A[=+\-@]/) ? "'#{text}" : text
    end

    def decimal_amount(minor, exponent)
      format("%.#{exponent}f", BigDecimal(minor.to_s) / (10**exponent))
    end

    def sap_date(date) = date.strftime("%Y%m%d")

    def parse_date(value, field)
      value.is_a?(Date) ? value : Date.iso8601(value.to_s)
    rescue Date::Error
      raise InvalidExport, "#{field.to_s.humanize} must be a valid ISO date"
    end
  end
end
