# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"
require "tempfile"
require "zip"

class Khata::ArchiveTest < ActiveSupport::TestCase
  CORPUS = Rails.root.join("conformance/corpus/files/consulting.khata")

  test "verifies the container, SQLite books, audit chain, and declared signatures" do
    Khata::Archive.open(CORPUS) do |archive|
      assert_equal "51a95604-29bd-4951-b357-836221330c2d", archive.workspace_id
      assert_equal 1_029, archive.audit_rows.size
      assert_equal "verified", archive.signature_status
      assert_equal archive.manifest.dig("integrity", "auditHead"), archive.audit_head
      assert archive.conformance.dig("runtimeFormatSubset", "ok")
      assert archive.conformance.dig("chainAndSignatures", "ok")
      assert_equal 1, archive.conformance.dig("chainAndSignatures", "signingKeys")
      assert_equal 960, archive.entry_event_seq_by_source_entry.size
      assert_equal 8, archive.trial_balance.size
    end
  end

  test "rejects a manifest whose books hash was tampered" do
    bytes = Zip::OutputStream.write_buffer do |output|
      Zip::File.open(CORPUS) do |source|
        source.each do |entry|
          output.put_next_entry(entry.name)
          if entry.name == "manifest.json"
            manifest = JSON.parse(entry.get_input_stream.read)
            manifest.fetch("integrity")["booksHash"] = "0" * 64
            output.write(JSON.generate(manifest))
          elsif !entry.directory?
            output.write(entry.get_input_stream.read)
          end
        end
      end
    end.string

    with_archive(bytes) do |path|
      error = assert_raises(Khata::Archive::InvalidArchive) { Khata::Archive.open(path) }
      assert_match(/does not match/, error.message)
    end
  end

  test "rejects traversal member names before extraction" do
    bytes = Zip::OutputStream.write_buffer do |output|
      output.put_next_entry("../manifest.json")
      output.write("{}")
      output.put_next_entry("books.sqlite")
      output.write("not a database")
    end.string

    with_archive(bytes) do |path|
      error = assert_raises(Khata::Archive::InvalidArchive) { Khata::Archive.open(path) }
      assert_match(/unsafe archive member path/, error.message)
    end
  end

  test "rejects balanced projection entries that have no signed posting event" do
    books = Tempfile.new([ "khata-unlinked-entry", ".sqlite" ])
    books.binmode
    books.write(source_member("books.sqlite"))
    books.flush
    database = SQLite3::Database.new(books.path)
    next_entry = database.get_first_value("SELECT MAX(id) + 1 FROM entries")
    next_line = database.get_first_value("SELECT MAX(id) + 1 FROM entry_lines")
    database.execute(
      "INSERT INTO entries (id, posted_at, voucher_type, narration, created_at) " \
      "VALUES (?, '2026-08-01', 'JV', 'unsigned projection', '2026-08-01T00:00:00Z')",
      [ next_entry ]
    )
    accounts = database.execute("SELECT id, name FROM accounts ORDER BY id LIMIT 2")
    database.execute(
      "INSERT INTO entry_lines (id, entry_id, account_id, debit, credit, account_name) " \
      "VALUES (?, ?, ?, 1, 0, ?)",
      [ next_line, next_entry, accounts.first.fetch(0), accounts.first.fetch(1) ]
    )
    database.execute(
      "INSERT INTO entry_lines (id, entry_id, account_id, debit, credit, account_name) " \
      "VALUES (?, ?, ?, 0, 1, ?)",
      [ next_line + 1, next_entry, accounts.second.fetch(0), accounts.second.fetch(1) ]
    )
    database.close
    database = nil

    manifest = JSON.parse(source_member("manifest.json"))
    manifest.fetch("integrity")["booksHash"] = Digest::SHA256.file(books.path).hexdigest
    bytes = rebuilt_archive(manifest: manifest, books: File.binread(books.path))

    with_archive(bytes) do |path|
      error = assert_raises(Khata::Archive::InvalidArchive) { Khata::Archive.open(path) }
      assert_match(/no signed source posting event/, error.message)
    end
  ensure
    database&.close
    books&.close!
  end

  test "rejects archives that make no verifiable signature declaration" do
    manifest = JSON.parse(source_member("manifest.json"))
    manifest.fetch("integrity").delete("signedBy")
    bytes = rebuilt_archive(manifest: manifest, books: source_member("books.sqlite"))

    with_archive(bytes) do |path|
      error = assert_raises(Khata::Archive::InvalidArchive) { Khata::Archive.open(path) }
      assert_match(/must declare signing keys/, error.message)
    end
  end

  private

  def with_archive(bytes)
    file = Tempfile.new([ "khata-archive-test", ".khata" ])
    file.binmode
    file.write(bytes)
    file.flush
    yield file.path
  ensure
    file&.close!
  end

  def source_member(name)
    Zip::File.open(CORPUS) { |source| source.find_entry(name).get_input_stream.read }
  end

  def rebuilt_archive(manifest:, books:)
    Zip::OutputStream.write_buffer do |output|
      output.put_next_entry("books.sqlite")
      output.write(books)
      output.put_next_entry("manifest.json")
      output.write(JSON.generate(manifest))
    end.string
  end
end
