# frozen_string_literal: true

require "test_helper"
require "csv"
require "digest"
require "json"
require "stringio"
require "zip"

class SapBusinessOneDtwExportTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "sap-export@folio.invalid", password: "correct-horse-battery",
      org_name: "SAP Export"
    )
    @entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @ledger = Ledger.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
  end

  test "entity package is deterministic balanced and independently checksummed" do
    post_journal
    first = export(scope: "entity", entity_id: @entity.id)
    second = export(scope: "entity", entity_id: @entity.id)
    assert_equal first.bytes, second.bytes
    assert_match(/folio-sap-b1-dtw-entity-primary-2026-08-01-2026-08-31\.zip/, first.filename)

    files = unzip(first.bytes)
    assert_equal [
      "FOLIO - AccountCrosswalk.csv", "FOLIO - BusinessPartnerCrosswalk.csv",
      "FOLIO - SourceEvents.csv", "FOLIO-MANIFEST.json", "JDT1 - JournalEntries_Lines.csv",
      "OACT - ChartOfAccounts.csv", "OCRD - BusinessPartners.csv", "OJDT - JournalEntries.csv"
    ], files.keys.sort
    headers = CSV.parse(files.fetch("OJDT - JournalEntries.csv"), headers: true)
    lines = CSV.parse(files.fetch("JDT1 - JournalEntries_Lines.csv"), headers: true)
    assert_equal 1, headers.size
    assert_equal "20260815", headers.sole.fetch("ReferenceDate")
    assert_equal %w[100.00 0.00], lines.map { |line| line.fetch("Debit") }
    assert_equal %w[0.00 100.00], lines.map { |line| line.fetch("Credit") }

    manifest = JSON.parse(files.fetch("FOLIO-MANIFEST.json"))
    assert_equal 1, manifest.fetch("journalCount")
    assert_equal 2, manifest.fetch("lineCount")
    assert_equal manifest.fetch("debitMinor"), manifest.fetch("creditMinor")
    manifest.fetch("files").each do |name, evidence|
      assert_equal Digest::SHA256.hexdigest(files.fetch(name)), evidence.fetch("sha256")
      assert_equal files.fetch(name).bytesize, evidence.fetch("bytes")
    end
    assert_equal LedgerEvent.for_tenant(@org.tenant.id).maximum(:seq),
      manifest.dig("ledgerChainHead", "seq")
  end

  test "group package contains legal and elimination journals without touching legal books" do
    group = ConsolidationGroup.find_by!(tenant_id: @org.tenant.id, code: "GROUP")
    buyer = Consolidation::Manage.create_entity!(
      tenant: @org.tenant, group: group, actor: @org.user,
      attributes: {
        code: "SUB", legal_name: "SAP Subsidiary", office_name: "SAP Subsidiary Office",
        effective_from: "2026-04-01"
      }
    )
    transaction = Consolidation::PostIntercompany.call(
      group: group, actor: @org.user,
      attributes: {
        seller_entity_id: @entity.id, buyer_entity_id: buyer.id,
        posting_date: "2026-08-15", amount: "100", description: "Shared services",
        seller_receivable_account_code: "1200", seller_revenue_account_code: "4000",
        buyer_expense_account_code: "5100", buyer_payable_account_code: "2000",
        idempotency_key: "sap-export-intercompany"
      }
    )
    Consolidation::Eliminate.call(
      transaction: transaction, actor: @org.user,
      attributes: { posting_date: "2026-08-31", idempotency_key: "sap-export-elimination" }
    )

    result = export(scope: "group", group_id: group.id)
    files = unzip(result.bytes)
    headers = CSV.parse(files.fetch("OJDT - JournalEntries.csv"), headers: true)
    lines = CSV.parse(files.fetch("JDT1 - JournalEntries_Lines.csv"), headers: true)
    source = CSV.parse(files.fetch("FOLIO - SourceEvents.csv"), headers: true)
    assert_equal 2, headers.size
    assert_equal 8, lines.size
    assert_equal 2, source.size
    lines.group_by { |line| line.fetch("RecordKey") }.each_value do |journal|
      assert_equal journal.sum { |line| BigDecimal(line.fetch("Debit")) },
        journal.sum { |line| BigDecimal(line.fetch("Credit")) }
    end
    assert_equal 4, EntryLine.where(
      tenant_id: @org.tenant.id, posting_layer: "00",
      intercompany_transaction_id: transaction.transaction_code
    ).count
  end

  test "an office export fails closed when a selected line has no reporting-currency slot" do
    entry = post_journal
    entry.entry_lines.first.amounts.delete_all
    error = assert_raises(SapBusinessOne::InvalidExport) do
      export(scope: "office", office_id: @office.id)
    end
    assert_match(/has no INR amount/, error.message)
  end

  test "group range export retains a member that exited before the range end" do
    group = ConsolidationGroup.find_by!(tenant_id: @org.tenant.id, code: "GROUP")
    buyer = Consolidation::Manage.create_entity!(
      tenant: @org.tenant, group: group, actor: @org.user,
      attributes: {
        code: "EXITED", legal_name: "Exited Subsidiary", office_name: "Exited Office",
        effective_from: "2026-08-01"
      }
    )
    group.consolidation_group_members.find_by!(entity_id: buyer.id)
      .update!(effective_to: Date.new(2026, 8, 20))
    post_entity_journal(buyer, Date.new(2026, 8, 15))

    result = export(scope: "group", group_id: group.id)

    assert_equal 1, result.manifest.fetch("journalCount")
    assert_equal 2, result.manifest.fetch("lineCount")
  end

  private

  def post_journal
    Posting::PostEntry.post!(
      tenant_id: @org.tenant.id, actor: "u:#{@org.user.id}", actor_user_id: @org.user.id,
      office_id: @office.id, document_date: Date.new(2026, 8, 15),
      posting_date: Date.new(2026, 8, 15), entered_at: Time.utc(2026, 8, 15, 9),
      fiscal_year: 2026, period_no: 5,
      lines: [
        line(1, "1000", 10_000), line(2, "4000", -10_000)
      ]
    )
  end

  def post_entity_journal(entity, date)
    office = Office.where(tenant_id: @org.tenant.id, entity_id: entity.id).first!
    Posting::PostEntry.post!(
      tenant_id: @org.tenant.id, actor: "u:#{@org.user.id}", actor_user_id: @org.user.id,
      office_id: office.id, document_date: date, posting_date: date,
      entered_at: date.to_time, fiscal_year: 2026, period_no: 5,
      lines: [
        line(1, "1000", 10_000, entity: entity, office: office),
        line(2, "4000", -10_000, entity: entity, office: office)
      ]
    )
  end

  def line(number, account_code, amount_minor, entity: @entity, office: @office)
    {
      line_no: number, account_code: account_code, ledger_id: @ledger.id,
      entity_id: entity.id, office_id: office.id,
      amounts: [
        { slot_role: "functional", currency: entity.functional_currency, minor_unit_exponent: 2,
          amount_minor: amount_minor }
      ]
    }
  end

  def export(scope:, **identifiers)
    SapBusinessOne::DtwExport.call(
      tenant: @org.tenant, scope: scope, from_date: "2026-08-01", to_date: "2026-08-31",
      **identifiers
    )
  end

  def unzip(bytes)
    files = nil
    Zip::File.open_buffer(StringIO.new(bytes)) do |archive|
      files = archive.entries.to_h { |entry| [ entry.name, entry.get_input_stream.read ] }
    end
    files
  end
end
