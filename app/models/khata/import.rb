# frozen_string_literal: true

require "sqlite3"
require "tempfile"

# B3.5 — the THIN .khata import (the seed of the M4 bridge, not M4 itself).
#
# Reads a .khata's Bahi projection (books.sqlite: accounts, entries, entry_lines) and loads
# it into Folio's projection (accounts, entries, entry_lines, journal_entry_line_amounts) so
# the corpus report queries can run through the NEW model and match Tier R golden output
# byte-for-byte. Scope discipline — this slice does ONLY that:
#   - projection only: it does NOT append to ledger_events (the chain / Tier C is proven
#     separately by ingest_verbatim!); the full M4 bridge will unify the two.
#   - no import UI, no conflict handling, no write-back to .khata.
#   - conformance/ is opened READ-ONLY (books.sqlite copied to a tempfile).
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

    def initialize(khata_path, tenant_id, currency, minor_unit_exponent)
      @khata_path = khata_path.to_s
      @tenant_id = tenant_id
      @currency = currency.to_s.upcase
      @minor_unit_exponent = Integer(minor_unit_exponent)
      validate_currency_profile!
    rescue ArgumentError, TypeError
      raise InvalidCurrencyProfile, CURRENCY_PROFILE_ERROR
    end

    def import!
      with_books do |db|
        ActiveRecord::Base.transaction do
          wipe!
          import_accounts(db)
          import_entries_and_lines(db)
        end
      end
      { accounts: Account.where(tenant_id: @tenant_id).count,
        entries: Entry.where(tenant_id: @tenant_id).count,
        lines: EntryLine.where(tenant_id: @tenant_id).count }
    end

    private

    # Idempotent: a re-import replaces this tenant's projection wholesale.
    def wipe!
      Entry.where(tenant_id: @tenant_id).destroy_all
      Account.where(tenant_id: @tenant_id).delete_all
    end

    def import_accounts(db)
      now = Time.now.utc
      rows = db.execute("SELECT id, name, type FROM accounts").map do |r|
        { tenant_id: @tenant_id, code: r["id"].to_s, name: r["name"], account_type: r["type"],
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
          fiscal_year: fy, period_no: period
        )
        folio_id[e["id"]] = entry.id
      end

      # 2) lines — bulk. Build the source list, insert entry_lines, re-read their ids, then
      #    insert the amounts keyed by (entry_id, line_no).
      line_no_by_entry = Hash.new(0)
      source = db.execute("SELECT id, entry_id, account_id, debit, credit FROM entry_lines ORDER BY entry_id, id").map do |l|
        eid = folio_id.fetch(l["entry_id"])
        ln = (line_no_by_entry[eid] += 1)
        { entry_id: eid, line_no: ln, account_code: l["account_id"].to_s,
          amount_minor: signed_amount!(l) }
      end
      return if source.empty?

      EntryLine.insert_all!(
        source.map do |s|
          { tenant_id: @tenant_id, entry_id: s[:entry_id], line_no: s[:line_no],
            account_code: s[:account_code], ledger_id: 1, entity_id: 1, office_id: 1,
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
