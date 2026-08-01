# frozen_string_literal: true

require "tempfile"
require "set"

# Projection loader shared by the read-only conformance harness and the guarded product bridge.
#
# Reads a .khata's Bahi projection (books.sqlite: accounts, entries, entry_lines) and loads
# it into Folio's projection (accounts, entries, entry_lines, journal_entry_line_amounts). Direct
# `import!` stays projection-only for the corpus tests. `Khata::Bridge` performs safe archive and
# signature verification, stores the exact source chain, invokes `import_database!` inside the same
# transaction, and persists immutable evidence. Nothing writes into `conformance/`.
#
# Mapping (verified against the corpus):
#   Bahi account.id -> Folio account.code (string); Bahi has no separate code.
#   Bahi (debit, credit) — always one-zero and non-negative across the whole corpus ->
#     signed amount_minor = debit - credit. The source has no currency metadata, so callers
#     must explicitly declare the currency and ISO 4217 exponent instead of inheriting INR/2.
#     The report reconstructs debit/credit by sign.
#
# Bulk-inserts (insert_all!) because the corpus runs to ~22k lines per file; per-row create!
# would take minutes.
module Khata
  class Import
    InvalidLineAmount = Class.new(StandardError)
    InvalidCurrencyProfile = Class.new(StandardError)
    CURRENCY_PROFILE_ERROR =
      "declare a three-letter currency and ISO 4217 minor-unit exponent between 0 and 4"

    def self.import!(khata_path:, tenant_id:, currency:, minor_unit_exponent:)
      new(khata_path, tenant_id, currency, minor_unit_exponent).import!
    end

    def self.import_database!(database:, tenant_id:, currency:, minor_unit_exponent:,
                              entity_id:, office_id:, ledger_event_id_by_source_entry: {})
      new(nil, tenant_id, currency, minor_unit_exponent,
        entity_id: entity_id, office_id: office_id,
        ledger_event_id_by_source_entry: ledger_event_id_by_source_entry).import_database!(database)
    end

    def initialize(khata_path, tenant_id, currency, minor_unit_exponent, entity_id: 1, office_id: 1,
                   ledger_event_id_by_source_entry: {})
      @khata_path = khata_path.to_s
      @tenant_id = tenant_id
      @currency = currency.to_s.upcase
      @minor_unit_exponent = Integer(minor_unit_exponent)
      @entity_id = entity_id
      @office_id = office_id
      @ledger_event_ids = ledger_event_id_by_source_entry
      validate_currency_profile!
    rescue ArgumentError, TypeError
      raise InvalidCurrencyProfile, CURRENCY_PROFILE_ERROR
    end

    def import!
      with_books do |db|
        import_database!(db)
      end
    end

    def import_database!(db)
      ActiveRecord::Base.transaction do
        wipe!
        import_accounts(db)
        seed_statement_mappings
        import_entries_and_lines(db)
      end
      { accounts: Account.where(tenant_id: @tenant_id).count,
        entries: Entry.where(tenant_id: @tenant_id).count,
        lines: EntryLine.where(tenant_id: @tenant_id).count }
    end

    private

    # Idempotent: a re-import replaces this tenant's projection wholesale.
    def wipe!
      Entry.where(tenant_id: @tenant_id).destroy_all
      FinancialStatementAssignment.where(tenant_id: @tenant_id).delete_all
      AssetClass.where(tenant_id: @tenant_id).delete_all
      Account.where(tenant_id: @tenant_id).delete_all
    end

    def seed_statement_mappings
      tenant = Tenant.find_by(id: @tenant_id)
      FinancialStatements::DefaultLayout.ensure!(tenant) if tenant
    end

    def import_accounts(db)
      now = Time.now.utc
      code = column?(db, "accounts", "folio_code") ? "folio_code" : "NULL AS folio_code"
      archived = column?(db, "accounts", "archived") ? "archived" : "0 AS archived"
      rows = db.execute("SELECT id, name, type, #{archived}, #{code} FROM accounts").map do |r|
        { tenant_id: @tenant_id, code: r["folio_code"].presence || r["id"].to_s,
          name: r["name"], account_type: r["type"], active: r["archived"].to_i.zero?,
          created_at: now, updated_at: now }
      end
      Account.insert_all!(rows) if rows.any?
    end

    def import_entries_and_lines(db)
      now = Time.now.utc

      # 1) entries — small (hundreds); create! per row to get a bahi_id -> folio_id map.
      folio_id = {}
      db.execute("SELECT id, posted_at, created_at FROM entries ORDER BY id").each do |e|
        posting = Date.parse(e["posted_at"])
        fy, period = indian_fy_period(posting)
        entry = Entry.create!(
          tenant_id: @tenant_id, document_date: posting, posting_date: posting,
          entered_at: (Time.parse(e["created_at"]) rescue posting.to_time),
          fiscal_year: fy, period_no: period,
          ledger_event_id: @ledger_event_ids[e["id"].to_i]
        )
        folio_id[e["id"]] = entry.id
      end

      # 2) lines — bulk. Build the source list, insert entry_lines, re-read their ids, then
      #    insert the amounts keyed by (entry_id, line_no).
      line_no_by_entry = Hash.new(0)
      ledger = column?(db, "entry_lines", "ledger") ? "ledger" : "NULL AS ledger"
      value_date = column?(db, "entry_lines", "value_date") ? "value_date" : "NULL AS value_date"
      account_name = column?(db, "entry_lines", "account_name") ?
        "account_name" : "NULL AS account_name"
      account_names = Account.where(tenant_id: @tenant_id).pluck(:code, :name).to_h
      account_codes = account_names.keys.to_set
      source_code = column?(db, "accounts", "folio_code") ?
        "folio_code" : "NULL AS folio_code"
      source_accounts = db.execute("SELECT id, #{source_code} FROM accounts")
        .to_h { |row| [ row["id"], row["folio_code"].presence || row["id"].to_s ] }
      source = db.execute(<<~SQL).map do |l|
        SELECT id, entry_id, account_id, debit, credit, #{ledger}, #{value_date}, #{account_name}
        FROM entry_lines ORDER BY entry_id, id
      SQL
        eid = folio_id.fetch(l["entry_id"])
        ln = (line_no_by_entry[eid] += 1)
        account_code = source_accounts.fetch(l["account_id"])
        raise KeyError, "source account #{account_code} was not imported" unless account_codes.include?(account_code)
        { entry_id: eid, line_no: ln, account_code: account_code,
          account_name: l["account_name"].presence || account_names.fetch(account_code),
          ledger_id: ledger_id(l["ledger"]), value_date: l["value_date"],
          source_event_id: @ledger_event_ids[l["entry_id"].to_i], amount_minor: signed_amount!(l) }
      end
      return if source.empty?

      EntryLine.insert_all!(
        source.map do |s|
          { tenant_id: @tenant_id, entry_id: s[:entry_id], line_no: s[:line_no],
            account_code: s[:account_code], ledger_id: s[:ledger_id],
            account_name: s[:account_name],
            entity_id: @entity_id, office_id: @office_id, value_date: s[:value_date],
            source_event_id: s[:source_event_id],
            created_at: now, updated_at: now }
        end
      )

      amount_by_key = source.to_h { |s| [ [ s[:entry_id], s[:line_no] ], s[:amount_minor] ] }
      amounts = EntryLine.where(tenant_id: @tenant_id).pluck(:id, :entry_id, :line_no).map do |id, eid, ln|
        { tenant_id: @tenant_id, entry_line_id: id, slot_role: "transaction", currency: @currency,
          minor_unit_exponent: @minor_unit_exponent, amount_minor: amount_by_key.fetch([ eid, ln ]),
          created_at: now, updated_at: now }
      end
      JournalEntryLineAmount.insert_all!(amounts)
    end

    def signed_amount!(line)
      debit = Integer(line["debit"])
      credit = Integer(line["credit"])
      valid = (debit.positive? && credit.zero?) || (credit.positive? && debit.zero?)
      unless valid
        raise InvalidLineAmount,
          "invalid debit/credit at entry #{line["entry_id"]} line #{line["id"]}: " \
          "expected exactly one positive side, got debit=#{debit} credit=#{credit}"
      end
      debit - credit
    end

    def ledger_id(source_code)
      code = source_code.presence || "BOOK"
      target_code = code == "BOOK" ? "PRIMARY" : code
      @ledger_ids ||= {}
      @ledger_ids[target_code] ||= Ledger.find_or_create_by!(tenant_id: @tenant_id, code: target_code) do |record|
        record.name = target_code == "PRIMARY" ? "Primary" : code.humanize
        record.kind = target_code == "PRIMARY" ? "standard" : "extension"
        record.posts_to_gl = true
      end.id
    end

    def column?(db, table, column)
      db.table_info(table).any? { |info| info["name"] == column }
    end

    def validate_currency_profile!
      return if @currency.match?(/\A[A-Z]{3}\z/) && @minor_unit_exponent.between?(0, 4)

      raise InvalidCurrencyProfile, CURRENCY_PROFILE_ERROR
    end

    # Indian FY (Apr–Mar): Apr→period 1 … Mar→period 12. Faithful, though the reports don't
    # depend on it — it only satisfies entries' NOT NULL (fiscal_year, period_no).
    def indian_fy_period(date)
      if date.month >= 4
        [ date.year, date.month - 3 ]
      else
        [ date.year - 1, date.month + 9 ]
      end
    end

    def with_books
      require "sqlite3"
      tmp = Tempfile.new([ "khata-import", ".sqlite" ])
      tmp.close
      unless system("unzip", "-p", @khata_path, "books.sqlite", out: tmp.path)
        raise "unzip failed to extract books.sqlite from #{@khata_path}"
      end
      db = SQLite3::Database.new(tmp.path)
      db.results_as_hash = true
      yield db
    ensure
      db&.close
      tmp&.unlink
    end
  end
end
