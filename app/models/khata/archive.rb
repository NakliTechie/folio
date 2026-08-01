# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "sqlite3"
require "tempfile"
require "zip"

module Khata
  class Archive
    InvalidArchive = Class.new(StandardError)
    MAX_ARCHIVE_BYTES = 100.megabytes
    MAX_BOOKS_BYTES = 250.megabytes
    MAX_MANIFEST_BYTES = 2.megabytes
    MAX_ENTRIES = 10_000
    MAX_TOTAL_UNCOMPRESSED_BYTES = 500.megabytes
    MAX_ACCOUNTS = 50_000
    MAX_JOURNAL_ENTRIES = 100_000
    MAX_ENTRY_LINES = 500_000
    MAX_AUDIT_ROWS = 250_000
    MAX_AUDIT_PAYLOAD_BYTES = 1.megabyte
    MAX_TOTAL_AUDIT_PAYLOAD_BYTES = 100.megabytes
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
    REQUIRED_TABLES = %w[accounts entries entry_lines audit_log meta].freeze

    attr_reader :path, :manifest, :books_sha256, :audit_rows, :signature_status,
      :signing_keys, :entry_event_seq_by_source_entry

    def self.open(path)
      archive = new(path)
      return archive unless block_given?

      begin
        yield archive
      ensure
        archive.close
      end
    end

    def initialize(path)
      @path = path.to_s
      validate_container!
      extract_and_open_books!
      validate_database!
      verify_chain_and_signatures!
      validate_entry_correspondence!
    rescue InvalidArchive
      close
      raise
    rescue JSON::ParserError, Zip::Error, SQLite3::Exception, Errno::ENOENT,
           KeyError, TypeError, ArgumentError => e
      close
      raise InvalidArchive, "Invalid .khata archive: #{e.message}"
    end

    def close
      @database&.close
      @books_file&.close!
      @zip&.close
      @database = @books_file = @zip = nil
    end

    def database = @database

    def workspace_id = manifest.fetch("workspaceId")

    def audit_head = audit_rows.last.fetch("hash")

    def conformance
      {
        "runtimeFormatSubset" => {
          "ok" => true, "booksSha256" => books_sha256,
          "schemaVersion" => manifest.fetch("schemaVersion"),
          "checks" => %w[container sqlite-integrity foreign-keys journal-balance line-shape]
        },
        "chainAndSignatures" => {
          "ok" => true, "auditRows" => audit_rows.size,
          "auditHead" => audit_head, "signatureStatus" => signature_status,
          "signingKeys" => signing_keys.size
        }
      }
    end

    def signer_fingerprint_for(row)
      row["signer_fingerprint"].presence || signing_keys.keys.sole
    end

    def trial_balance
      code_sql = column?("accounts", "folio_code") ?
        "COALESCE(a.folio_code, CAST(a.id AS TEXT))" : "CAST(a.id AS TEXT)"
      database.execute(<<~SQL).map do |row|
        SELECT #{code_sql} AS account_code, COALESCE(el.account_name, a.name) AS name, a.type AS type,
          SUM(el.debit) AS debit, SUM(el.credit) AS credit
        FROM entry_lines el JOIN accounts a ON a.id = el.account_id
        GROUP BY a.id, COALESCE(el.account_name, a.name) ORDER BY a.id
      SQL
        code = row.fetch("account_code")
        { "account_id" => code.match?(/\A\d+\z/) ? code.to_i : code,
          "name" => row.fetch("name"), "type" => row.fetch("type"),
          "debit" => row.fetch("debit"), "credit" => row.fetch("credit") }
      end
    end

    def account_type_totals
      database.execute(<<~SQL).map do |row|
        SELECT a.type AS type, SUM(el.debit) AS debit, SUM(el.credit) AS credit
        FROM entry_lines el JOIN accounts a ON a.id = el.account_id
        GROUP BY a.type ORDER BY a.type
      SQL
        { "type" => row.fetch("type"), "debit" => row.fetch("debit"),
          "credit" => row.fetch("credit") }
      end
    end

    def column?(table, column)
      database.table_info(table).any? { |info| info.fetch("name") == column }
    end

    private

    def validate_container!
      size = File.size(path)
      raise InvalidArchive, ".khata file is empty" if size.zero?
      raise InvalidArchive, ".khata file exceeds the 100 MB upload limit" if size > MAX_ARCHIVE_BYTES

      @zip = Zip::File.open(path)
      entries = @zip.entries
      raise InvalidArchive, ".khata archive contains too many members" if entries.size > MAX_ENTRIES
      entries.each { |entry| validate_entry_name!(entry.name) }
      total = entries.sum(&:size)
      if total > MAX_TOTAL_UNCOMPRESSED_BYTES
        raise InvalidArchive, ".khata archive expands beyond the 500 MB safety limit"
      end
      %w[manifest.json books.sqlite].each do |name|
        count = entries.count { |entry| entry.name == name }
        raise InvalidArchive, ".khata archive must contain exactly one #{name}" unless count == 1
      end
      manifest_entry = @zip.find_entry("manifest.json")
      books_entry = @zip.find_entry("books.sqlite")
      raise InvalidArchive, "manifest.json exceeds 2 MB" if manifest_entry.size > MAX_MANIFEST_BYTES
      raise InvalidArchive, "books.sqlite exceeds 250 MB" if books_entry.size > MAX_BOOKS_BYTES

      @manifest = JSON.parse(read_limited_entry(
        manifest_entry, MAX_MANIFEST_BYTES, "manifest.json exceeds 2 MB"
      ))
      validate_manifest!
    end

    def read_limited_entry(entry, limit, message)
      input = entry.get_input_stream
      output = +"".b
      while (chunk = input.read(64.kilobytes))
        output << chunk
        raise InvalidArchive, message if output.bytesize > limit
      end
      output
    end

    def validate_entry_name!(name)
      parts = name.split("/")
      invalid = name.include?("\0") || name.include?("\\") || Pathname.new(name).absolute? ||
        parts.include?("..")
      raise InvalidArchive, "unsafe archive member path: #{name.inspect}" if invalid
    end

    def validate_manifest!
      raise InvalidArchive, "unsupported .khata format version" unless manifest["khataFormatVersion"] == "1.0"
      version = Integer(manifest.fetch("schemaVersion"))
      raise InvalidArchive, "unsupported .khata schema version #{version}" unless version.between?(1, 12)
      raise InvalidArchive, "manifest workspaceId is not a UUID" unless manifest.fetch("workspaceId", "").match?(UUID)
      raise InvalidArchive, "manifest company name is required" if manifest.dig("company", "name").blank?
      integrity = manifest.fetch("integrity")
      unless integrity.fetch("booksHash", "").match?(/\A[0-9a-f]{64}\z/) &&
          integrity.fetch("auditHead", "").match?(/\A[0-9a-f]{64}\z/)
        raise InvalidArchive, "manifest integrity hashes must be lowercase SHA-256 hex"
      end
    rescue ArgumentError, TypeError
      raise InvalidArchive, "manifest schemaVersion must be an integer"
    end

    def extract_and_open_books!
      @books_file = Tempfile.new([ "folio-khata", ".sqlite" ])
      @books_file.binmode
      digest = Digest::SHA256.new
      input = @zip.find_entry("books.sqlite").get_input_stream
      extracted_bytes = 0
      while (chunk = input.read(64.kilobytes))
        extracted_bytes += chunk.bytesize
        raise InvalidArchive, "books.sqlite exceeds 250 MB" if extracted_bytes > MAX_BOOKS_BYTES
        @books_file.write(chunk)
        digest.update(chunk)
      end
      @books_file.flush
      @books_sha256 = digest.hexdigest
      unless books_sha256 == manifest.dig("integrity", "booksHash")
        raise InvalidArchive, "books.sqlite SHA-256 does not match manifest.integrity.booksHash"
      end
      @database = SQLite3::Database.new(@books_file.path, readonly: true)
      @database.results_as_hash = true
      @database.execute("PRAGMA query_only = ON")
    end

    def validate_database!
      integrity = database.get_first_value("PRAGMA integrity_check")
      raise InvalidArchive, "SQLite integrity_check failed: #{integrity}" unless integrity == "ok"
      tables = database.execute("SELECT name FROM sqlite_master WHERE type='table'")
        .map { |row| row.fetch("name") }
      missing = REQUIRED_TABLES - tables
      raise InvalidArchive, "books.sqlite is missing tables: #{missing.join(', ')}" if missing.any?
      meta_version = database.get_first_value("SELECT v FROM meta WHERE k='schemaVersion'")
      schema_version = Integer(meta_version)
      unless schema_version == Integer(manifest.fetch("schemaVersion"))
        raise InvalidArchive, "manifest and books.sqlite schema versions disagree"
      end
      foreign_key_error = database.execute("PRAGMA foreign_key_check").first
      if foreign_key_error
        raise InvalidArchive,
          "books.sqlite contains a broken foreign key in #{foreign_key_error.fetch('table')}"
      end
      bad = database.execute(<<~SQL)
        SELECT entry_id FROM entry_lines GROUP BY entry_id
        HAVING SUM(debit) <> SUM(credit) LIMIT 1
      SQL
      raise InvalidArchive, "books.sqlite contains an unbalanced journal" if bad.any?
      invalid_amount = database.get_first_value(<<~SQL)
        SELECT COUNT(*) FROM entry_lines
        WHERE debit < 0 OR credit < 0 OR (debit > 0 AND credit > 0) OR (debit = 0 AND credit = 0)
      SQL
      raise InvalidArchive, "books.sqlite contains an invalid debit/credit line" unless invalid_amount.to_i.zero?
      enforce_row_limit!("accounts", MAX_ACCOUNTS)
      enforce_row_limit!("entries", MAX_JOURNAL_ENTRIES)
      enforce_row_limit!("entry_lines", MAX_ENTRY_LINES)
      enforce_row_limit!("audit_log", MAX_AUDIT_ROWS)
      payload_limits = database.get_first_row(<<~SQL)
        SELECT COALESCE(MAX(length(CAST(payload AS BLOB))), 0) AS largest,
          COALESCE(SUM(length(CAST(payload AS BLOB))), 0) AS total
        FROM audit_log
      SQL
      if payload_limits.fetch("largest").to_i > MAX_AUDIT_PAYLOAD_BYTES
        raise InvalidArchive, "audit_log contains a payload larger than 1 MB"
      end
      if payload_limits.fetch("total").to_i > MAX_TOTAL_AUDIT_PAYLOAD_BYTES
        raise InvalidArchive, "audit_log payloads exceed the 100 MB processing limit"
      end
      if schema_version >= 2
        missing_snapshot = database.get_first_value(<<~SQL)
          SELECT COUNT(*) FROM entry_lines WHERE account_name IS NULL OR account_name = ''
        SQL
        unless missing_snapshot.to_i.zero?
          raise InvalidArchive, "books.sqlite contains a line without a frozen account name"
        end
      end
    rescue ArgumentError, TypeError
      raise InvalidArchive, "books.sqlite schema version is missing or invalid"
    end

    def enforce_row_limit!(table, limit)
      count = database.get_first_value("SELECT COUNT(*) FROM #{table}").to_i
      raise InvalidArchive, "#{table} contains #{count} rows; maximum is #{limit}" if count > limit
    end

    def verify_chain_and_signatures!
      hash_version = column?("audit_log", "hash_version") ? "hash_version" : "NULL AS hash_version"
      signer = column?("audit_log", "signer_fingerprint") ?
        "signer_fingerprint" : "NULL AS signer_fingerprint"
      @audit_rows = database.execute(<<~SQL)
        SELECT id, ts, actor, action, ref, origin, payload, prev_hash, hash, signature,
          #{hash_version}, #{signer} FROM audit_log ORDER BY id
      SQL
      raise InvalidArchive, "audit_log is empty" if audit_rows.empty?

      previous = Folio::KhataHash::GENESIS_PREV
      audit_rows.each_with_index do |row, index|
        unless Integer(row["id"]) == index + 1
          raise InvalidArchive, "audit row ids must be contiguous from 1"
        end
        genesis = previous == Folio::KhataHash::GENESIS_PREV &&
          (row["prev_hash"].blank? || row["prev_hash"] == Folio::KhataHash::GENESIS_PREV)
        unless row["prev_hash"] == previous || genesis
          raise InvalidArchive, "audit chain link failed at source row #{row['id']}"
        end
        unless Folio::KhataHash.row_hash(row) == row["hash"]
          raise InvalidArchive, "audit hash failed at source row #{row['id']}"
        end
        raise InvalidArchive, "audit row #{row['id']} has no origin" if row["origin"].blank?
        raise InvalidArchive, "audit row #{row['id']} has no canonical payload" if row["payload"].nil?
        previous = row["hash"]
      end
      unless previous == manifest.dig("integrity", "auditHead")
        raise InvalidArchive, "audit head does not match manifest.integrity.auditHead"
      end
      verify_signatures!
    rescue ArgumentError, TypeError
      raise InvalidArchive, "audit row ids must be integers contiguous from 1"
    end

    def verify_signatures!
      @signing_keys = manifest_signing_keys
      audit_rows.each do |row|
        fingerprint = signer_fingerprint_for(row)
        jwk = signing_keys[fingerprint]
        unless row["signature"].present? && Khata::Signatures.verify(
          hash_hex: row.fetch("hash"), signature: row.fetch("signature"), jwk: jwk
        )
          raise InvalidArchive, "audit signature failed at source row #{row['id']}"
        end
      end
      @signature_status = "verified"
    end

    def manifest_signing_keys
      integrity = manifest.fetch("integrity")
      declared = Array(integrity["signingKeys"])
      if declared.empty? && integrity["signedBy"].present?
        jwk = integrity.fetch("signedBy")
        declared = [ { "fingerprint" => Khata::Signatures.fingerprint(jwk), "jwk" => jwk } ]
      end
      raise InvalidArchive, ".khata archives must declare signing keys" if declared.empty?

      declared.each_with_object({}) do |item, keys|
        jwk = item.fetch("jwk")
        fingerprint = item.fetch("fingerprint")
        unless fingerprint.match?(/\A[0-9a-f]{64}\z/) &&
            ActiveSupport::SecurityUtils.secure_compare(fingerprint, Khata::Signatures.fingerprint(jwk))
          raise InvalidArchive, ".khata signing-key fingerprint is invalid"
        end
        raise InvalidArchive, ".khata signing-key fingerprints must be unique" if keys.key?(fingerprint)

        Khata::Signatures.public_key(jwk)
        keys[fingerprint] = jwk
      end
    end

    def validate_entry_correspondence!
      source = if column?("entries", "folio_ledger_event_seq")
        database.execute("SELECT id, folio_ledger_event_seq AS event_seq FROM entries ORDER BY id")
      else
        refs = audit_rows.filter_map do |row|
          match = row["ref"].to_s.match(/\Aentry:(\d+)\z/)
          next unless match && %w[entry.post entry.posted].include?(row["action"])

          [ match[1].to_i, Integer(row.fetch("id")) ]
        end.to_h
        database.execute("SELECT id FROM entries ORDER BY id").map do |entry|
          { "id" => entry.fetch("id"), "event_seq" => refs[entry.fetch("id").to_i] }
        end
      end

      events = audit_rows.index_by { |row| Integer(row.fetch("id")) }
      mapping = {}
      source.each do |entry|
        entry_id = Integer(entry.fetch("id"))
        seq = Integer(entry.fetch("event_seq"))
        event = events.fetch(seq)
        unless %w[entry.post entry.posted].include?(event["action"])
          raise InvalidArchive, "entry #{entry_id} points to non-posting audit row #{seq}"
        end
        if mapping.value?(seq)
          raise InvalidArchive, "audit row #{seq} is linked to more than one entry"
        end
        mapping[entry_id] = seq
      rescue TypeError, ArgumentError, KeyError
        raise InvalidArchive, "entry #{entry_id} has no signed source posting event"
      end
      @entry_event_seq_by_source_entry = mapping
    end
  end
end
