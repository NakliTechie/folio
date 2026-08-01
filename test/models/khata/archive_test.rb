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
      assert archive.conformance.dig("F", "ok")
      assert archive.conformance.dig("C", "ok")
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
end
