# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "sqlite3"
require "tempfile"
require "zip"

module Khata
  class Export
    InvalidExport = Class.new(StandardError)
    Result = Data.define(:bytes, :filename, :manifest)
    FIXED_ZIP_TIME = Time.utc(1980, 1, 1).freeze
    GST_TO_ISO = {
      "01" => "JK", "02" => "HP", "03" => "PB", "04" => "CH", "05" => "UK",
      "06" => "HR", "07" => "DL", "08" => "RJ", "09" => "UP", "10" => "BR",
      "11" => "SK", "12" => "AR", "13" => "NL", "14" => "MN", "15" => "MZ",
      "16" => "TR", "17" => "ML", "18" => "AS", "19" => "WB", "20" => "JH",
      "21" => "OD", "22" => "CG", "23" => "MP", "24" => "GJ", "26" => "DH",
      "27" => "MH", "29" => "KA", "30" => "GA", "31" => "LD", "32" => "KL",
      "33" => "TN", "34" => "PY", "35" => "AN", "36" => "TS", "37" => "AP",
      "38" => "LA", "97" => "OT"
    }.freeze

    def self.call(...) = new(...).call

    def initialize(tenant:, entity_id:)
      @tenant = tenant
      @entity = Entity.where(tenant_id: tenant.id).find(entity_id)
    end

    def call
      validate_scope!
      chain = LedgerEvent.verify_chain(tenant.id)
      unless chain[:ok] && chain[:rows].positive?
        raise InvalidExport, "A non-empty, verified ledger chain is required for .khata export."
      end

      records = journal_records
      books = build_books(records)
      manifest = build_manifest(books, chain)
      Result.new(
        bytes: zip("manifest.json" => JSON.pretty_generate(manifest) + "\n", "books.sqlite" => books),
        filename: "#{tenant.slug}-#{entity.code.downcase}.khata", manifest: manifest
      )
    end

    private

    attr_reader :tenant, :entity

    def validate_scope!
      unless Entity.where(tenant_id: tenant.id).count == 1
        raise InvalidExport, ".khata v1 represents one legal company; export a single-entity Folio company."
      end
      unless entity.jurisdiction_profile == "IN" && entity.functional_currency == "INR"
        raise InvalidExport, ".khata v1 stores Indian books in integer paise; only an INR India entity is representable."
      end
      if LedgerEvent.for_tenant(tenant.id).in_order.first&.prev_hash.nil?
        raise InvalidExport,
          ".khata schema 12 cannot represent a legacy NULL genesis without changing its audit hash."
      end

      lines = EntryLine.where(tenant_id: tenant.id, entity_id: entity.id)
      unsupported = lines.where.not(line_class: "real").or(lines.where.not(posting_layer: "00"))
        .or(lines.where.not(value_date: nil))
      if unsupported.exists?
        raise InvalidExport, ".khata v1 cannot represent statistical/layered postings or value dates."
      end
      primary = Ledger.find_by(tenant_id: tenant.id, code: "PRIMARY", posts_to_gl: true)
      if primary.nil? || lines.where.not(ledger_id: primary.id).exists?
        raise InvalidExport, ".khata v1 cannot represent Folio extension ledgers without the proposed v1.1 field."
      end
    end

    def journal_records
      lines = EntryLine.includes(:amounts, :ledger, entry: :document)
        .where(tenant_id: tenant.id, entity_id: entity.id)
        .order(:entry_id, :line_no, :id).to_a
      lines.group_by(&:entry_id).map do |_entry_id, grouped|
        rendered = grouped.map { |line| [ line, paise_amount(line) ] }
        total = rendered.sum { |_line, amount| amount }
        unless total.zero?
          raise InvalidExport, "Folio entry #{grouped.first.entry_id} is unbalanced by #{total} paise."
        end
        { entry: grouped.first.entry, lines: rendered }
      end
    end

    def paise_amount(line)
      candidates = line.amounts.select do |amount|
        %w[functional transaction].include?(amount.slot_role) &&
          amount.currency == "INR" && amount.minor_unit_exponent == 2
      end
      values = candidates.map(&:amount_minor).uniq
      return values.sole if values.one?

      raise InvalidExport,
        "Entry #{line.entry_id} line #{line.line_no} has no single unambiguous INR-paise amount."
    end

    def build_books(records)
      file = Tempfile.new([ "folio-export", ".sqlite" ])
      file.close
      database = SQLite3::Database.new(file.path)
      database.execute_batch(File.read(Rails.root.join("app/models/khata/schema_v12.sql")))
      database.execute("PRAGMA foreign_keys = ON")
      database.transaction do
        database.execute("INSERT INTO meta (k, v) VALUES ('schemaVersion', '12')")
        account_ids = write_accounts(database)
        entry_ids = write_entries(database, records, account_ids)
        write_audit_log(database)
        write_reversal_links(database, records, entry_ids)
      end
      database.execute("PRAGMA optimize")
      database.close
      database = nil
      File.binread(file.path)
    ensure
      database&.close
      file&.unlink
    end

    def write_accounts(database)
      accounts = Account.where(tenant_id: tenant.id).in_code_order.to_a
      @account_names = accounts.to_h { |account| [ account.code, account.name ] }
      accounts.each_with_index do |account, index|
        database.execute(
          "INSERT INTO accounts (id, name, type, system_flag, archived) VALUES (?, ?, ?, 0, ?)",
          [ index + 1, account.name, account.account_type, account.active? ? 0 : 1 ]
        )
      end
      accounts.each_with_index.to_h { |account, index| [ account.code, index + 1 ] }
    end

    def write_entries(database, records, account_ids)
      ids = {}
      line_id = 0
      records.each_with_index do |record, index|
        entry = record.fetch(:entry)
        export_id = index + 1
        ids[entry.id] = export_id
        document = entry.document
        source = source_entry_metadata(entry)
        entry_values = [
          export_id, entry.posting_date.iso8601, document&.doc_type || source["voucherType"] || "JV",
          document&.document_number || source["voucherRef"],
          document&.narration || "Folio entry #{entry.id}",
          event_actor(entry), entry.entered_at.utc.iso8601(3)
        ]
        database.execute(<<~SQL, entry_values)
          INSERT INTO entries
            (id, posted_at, voucher_type, voucher_ref, narration, created_by, created_at, is_amendment)
          VALUES (?, ?, ?, ?, ?, ?, ?, 0)
        SQL
        record.fetch(:lines).each_with_index do |(line, amount), line_index|
          line_id += 1
          debit, credit = amount.positive? ? [ amount, 0 ] : [ 0, -amount ]
          line_values = [
            line_id,
            export_id, account_ids.fetch(line.account_code), debit, credit,
            line.account_name.presence || @account_names.fetch(line.account_code)
          ]
          database.execute(<<~SQL, line_values)
            INSERT INTO entry_lines (id, entry_id, account_id, debit, credit, account_name)
            VALUES (?, ?, ?, ?, ?, ?)
          SQL
        end
      end
      ids
    end

    def write_reversal_links(database, records, entry_ids)
      records.each do |record|
        entry = record.fetch(:entry)
        target = entry_ids[entry.reversed_by_id]
        database.execute("UPDATE entries SET reversed_by_id = ? WHERE id = ?", [ target, entry_ids.fetch(entry.id) ]) if target
      end
    end

    def event_actor(entry)
      LedgerEvent.find_by(id: entry.ledger_event_id, tenant_id: tenant.id)&.actor || "folio"
    end

    def source_entry_metadata(entry)
      event = LedgerEvent.find_by(id: entry.ledger_event_id, tenant_id: tenant.id)
      return {} unless event&.action == "entry.post"

      JSON.parse(event.payload)
    rescue JSON::ParserError
      {}
    end

    def write_audit_log(database)
      LedgerEvent.for_tenant(tenant.id).in_order.each do |event|
        values = [
          event.seq, event.ts, event.actor, event.action, event.ref, event.origin, event.payload,
          event.prev_hash, event.hash_hex,
          event.signature.present? ? Base64.strict_encode64(event.signature) : nil,
          event.hash_version
        ]
        database.execute(<<~SQL, values)
          INSERT INTO audit_log
            (id, ts, actor, action, ref, origin, payload, prev_hash, hash, signature, hash_version)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
      end
    end

    def build_manifest(books, chain)
      source = KhataImportRun.find_by(tenant_id: tenant.id)
      integrity = { "booksHash" => Digest::SHA256.hexdigest(books), "auditHead" => chain.fetch(:head) }
      external_ids = LedgerEvent.for_tenant(tenant.id).distinct.pluck(:external_signing_key_id)
      if external_ids.one? && external_ids.first
        integrity["signedBy"] = ExternalSigningKey.find(external_ids.first).public_key_jwk
      end
      {
        "khataFormatVersion" => "1.0", "schemaVersion" => 12,
        "workspaceId" => source&.source_workspace_id || tenant.khata_workspace_id,
        "createdAt" => source&.source_manifest&.fetch("createdAt", nil) || tenant.created_at.utc.iso8601(3),
        "lastModifiedAt" => deterministic_last_modified(source),
        "company" => source&.source_manifest&.fetch("company", nil) || company_manifest,
        "uiTier" => source&.source_manifest&.fetch("uiTier", nil) || "everything",
        "snapshots" => [], "integrity" => integrity,
        "modeHistory" => source&.source_manifest&.fetch("modeHistory", nil) || []
      }
    end

    def deterministic_last_modified(source)
      event = LedgerEvent.for_tenant(tenant.id).in_order.last
      if source && event.seq == source.source_audit_rows && event.hash_hex == source.source_audit_head
        return source.source_manifest.fetch("lastModifiedAt")
      end
      Time.iso8601(event.ts).utc.iso8601(3)
    rescue ArgumentError
      event.recorded_at.utc.iso8601(3)
    end

    def company_manifest
      office = Office.find_by!(tenant_id: tenant.id, entity_id: entity.id, code: "PRIMARY")
      state_code = office.state_code
      unless office.country_code == "IN" && Taxes::India::StateCodes.valid?(state_code)
        raise InvalidExport, "Complete the primary Indian registered-office address before exporting .khata."
      end
      gstin = TaxRegistration.active.find_by(
        tenant_id: tenant.id, entity_id: entity.id, kind: "GSTIN"
      )&.identifier
      tan = TaxRegistration.active.find_by(
        tenant_id: tenant.id, entity_id: entity.id, kind: "TAN"
      )&.identifier
      {
        "name" => entity.legal_name, "trade_name" => nil, "company_type" => "other",
        "gstin" => gstin, "pan" => gstin&.slice(2, 10), "tan" => tan,
        "state" => GST_TO_ISO.fetch(state_code),
        "stateName" => Taxes::India::StateCodes.name_for(state_code),
        "gstinStateCode" => state_code,
        "address" => [ office.address_line1, office.address_line2, office.city, office.postal_code ].compact.join(", "),
        "fy_start" => fiscal_year_start.iso8601, "composition" => { "enabled" => false }
      }
    end

    def fiscal_year_start
      date = tenant.business_date
      Date.new(date.month >= 4 ? date.year : date.year - 1, 4, 1)
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
  end
end
