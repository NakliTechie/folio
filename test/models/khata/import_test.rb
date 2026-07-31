# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Khata::ImportTest < ActiveSupport::TestCase
  INVALID_AMOUNTS = {
    "both debit and credit" => [ 100, 20 ],
    "neither debit nor credit" => [ 0, 0 ],
    "a negative side" => [ -100, 0 ]
  }.freeze

  def with_khata(debit:, credit:)
    Dir.mktmpdir("folio-khata-import") do |dir|
      sqlite_path = File.join(dir, "books.sqlite")
      archive_path = File.join(dir, "invalid.khata")
      db = SQLite3::Database.new(sqlite_path)
      db.execute_batch(<<~SQL)
        CREATE TABLE accounts (id INTEGER PRIMARY KEY, name TEXT NOT NULL, type TEXT NOT NULL);
        CREATE TABLE entries (id INTEGER PRIMARY KEY, posted_at TEXT NOT NULL, created_at TEXT NOT NULL);
        CREATE TABLE entry_lines (
          id INTEGER PRIMARY KEY,
          entry_id INTEGER NOT NULL,
          account_id INTEGER NOT NULL,
          debit INTEGER NOT NULL,
          credit INTEGER NOT NULL
        );
        INSERT INTO accounts (id, name, type) VALUES (1, 'Cash', 'asset');
        INSERT INTO entries (id, posted_at, created_at)
          VALUES (1, '2025-06-01', '2025-06-01T09:00:00Z');
      SQL
      db.execute(
        "INSERT INTO entry_lines (id, entry_id, account_id, debit, credit) VALUES (1, 1, 1, ?, ?)",
        [ debit, credit ]
      )
      db.close
      raise "zip failed" unless system("zip", "-q", "-j", archive_path, sqlite_path)

      yield archive_path
    ensure
      db&.close
    end
  end

  INVALID_AMOUNTS.each do |label, (debit, credit)|
    test "rejects #{label} instead of silently netting the row" do
      tenant_id = 980_000 + SecureRandom.random_number(10_000)

      with_khata(debit: debit, credit: credit) do |path|
        error = assert_raises(Khata::Import::InvalidLineAmount) do
          Khata::Import.import!(khata_path: path, tenant_id: tenant_id,
            currency: "INR", minor_unit_exponent: 2)
        end

        assert_match(/expected exactly one positive side/, error.message)
        assert_equal 0, Account.where(tenant_id: tenant_id).count
        assert_equal 0, Entry.where(tenant_id: tenant_id).count
      end
    end
  end

  test "requires an explicit valid currency profile" do
    assert_raises(Khata::Import::InvalidCurrencyProfile) do
      Khata::Import.import!(khata_path: "unused.khata", tenant_id: 1,
        currency: "rupees", minor_unit_exponent: 2)
    end


    assert_raises(Khata::Import::InvalidCurrencyProfile) do
      Khata::Import.import!(khata_path: "unused.khata", tenant_id: 1,
        currency: "INR", minor_unit_exponent: "unknown")
    end
  end
end
