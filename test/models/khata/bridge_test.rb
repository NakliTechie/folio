# frozen_string_literal: true

require "test_helper"
require "tempfile"

class Khata::BridgeTest < ActiveSupport::TestCase
  CONSULTING = Rails.root.join("conformance/corpus/files/consulting.khata")
  PHARMA = Rails.root.join("conformance/corpus/files/pharma.khata")

  setup do
    @org = Onboarding::SignUp.call(
      email: "khata-bridge-owner@folio.invalid", password: "correct-horse-battery",
      org_name: "Khata Bridge"
    )
  end

  test "imports a verified source once with exact chain and native report parity" do
    result = Khata::Bridge.import!(
      tenant: @org.tenant, actor: @org.user, path: CONSULTING,
      filename: "consulting.khata"
    )

    refute result.duplicate
    run = result.run
    assert_equal 1_029, run.source_audit_rows
    assert_equal "verified", run.conformance.dig("chainAndSignatures", "signatureStatus")
    assert run.conformance.dig("nativeProjection", "ok")
    assert run.recovery_snapshot
    assert EventSigning.verify(run.domain_event)
    assert_equal "Arjun Rao Advisory LLP", @org.tenant.reload.name
    assert_equal "Arjun Rao Advisory LLP",
      Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY").legal_name
    assert_equal [ "TAN" ], TaxRegistration.where(tenant_id: @org.tenant.id).pluck(:kind)
    assert_match(/GSTIN failed/, run.conformance.dig("identity", "warnings").sole)
    assert_equal run.source_audit_head, LedgerEvent.verify_chain(@org.tenant.id)[:head]
    assert EventSigning.verify(LedgerEvent.for_tenant(@org.tenant.id).in_order.first)
    assert Entry.where(tenant_id: @org.tenant.id).where.not(ledger_event_id: nil).exists?

    assert_raises(ActiveRecord::StatementInvalid) do
      KhataImportRun.transaction(requires_new: true) { run.update_column(:source_filename, "changed.khata") }
    end
    key = run.external_signing_key
    assert_raises(ActiveRecord::StatementInvalid) do
      ExternalSigningKey.transaction(requires_new: true) { key.update_column(:fingerprint, "0" * 64) }
    end
    truncate_error = assert_raises(ActiveRecord::StatementInvalid) do
      KhataImportRun.transaction(requires_new: true) do
        KhataImportRun.connection.execute("TRUNCATE TABLE khata_import_runs CASCADE")
      end
    end
    assert_match(/TRUNCATE rejected/, truncate_error.message)

    Khata::Archive.open(CONSULTING) do |archive|
      assert_equal archive.trial_balance, Reports.trial_balance(@org.tenant.id)
      assert_equal archive.account_type_totals, Reports.account_type_totals(@org.tenant.id)
    end

    duplicate = Khata::Bridge.import!(
      tenant: @org.tenant, actor: @org.user, path: CONSULTING,
      filename: "renamed.khata"
    )
    assert duplicate.duplicate
    assert_equal run, duplicate.run

    error = assert_raises(Khata::Bridge::InvalidImport) do
      Khata::Bridge.import!(tenant: @org.tenant, actor: @org.user, path: PHARMA)
    end
    assert_match(/already imported a different/, error.message)
  end

  test "exports a deterministic standard archive that round-trips chain and ledger reports" do
    Khata::Bridge.import!(tenant: @org.tenant, actor: @org.user, path: CONSULTING)
    post_native_journal!
    entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")

    first = Khata::Export.call(tenant: @org.tenant, entity_id: entity.id)
    second = Khata::Export.call(tenant: @org.tenant, entity_id: entity.id)
    assert_equal first.bytes, second.bytes
    assert_equal "1.0", first.manifest.fetch("khataFormatVersion")
    assert_equal 12, first.manifest.fetch("schemaVersion")
    assert_equal 2, first.manifest.dig("integrity", "signingKeys").size
    assert_nil first.manifest.dig("integrity", "signedBy")

    archive_file = Tempfile.new([ "folio-round-trip", ".khata" ])
    archive_file.binmode
    archive_file.write(first.bytes)
    archive_file.flush
    Khata::Archive.open(archive_file.path) do |archive|
      assert_equal "verified", archive.signature_status
      assert_equal first.manifest.dig("integrity", "auditHead"), archive.audit_head

      target = Onboarding::SignUp.call(
        email: "khata-round-trip@folio.invalid", password: "correct-horse-battery",
        org_name: "Khata Round Trip"
      )
      imported = Khata::Bridge.import!(
        tenant: target.tenant, actor: target.user, path: archive_file.path
      )
      assert imported.run.conformance.dig("nativeProjection", "ok")
      assert_equal archive.trial_balance, Reports.trial_balance(target.tenant.id)
      assert_equal archive.audit_head, LedgerEvent.verify_chain(target.tenant.id)[:head]

      before_rebuild = Reports.trial_balance(target.tenant.id)
      Posting.rebuild!(target.tenant.id)
      assert_equal before_rebuild, Reports.trial_balance(target.tenant.id)
    end
  ensure
    archive_file&.close!
  end

  test "a signed Bahi import remains report-identical after routine projection rebuild" do
    Khata::Bridge.import!(tenant: @org.tenant, actor: @org.user, path: CONSULTING)
    before = Reports.trial_balance(@org.tenant.id)

    Posting.rebuild!(@org.tenant.id)

    assert_equal before, Reports.trial_balance(@org.tenant.id)
    assert_equal 960, Entry.where(tenant_id: @org.tenant.id).count
    assert EntryLine.where(tenant_id: @org.tenant.id).where.not(source_event_id: nil).exists?
  end

  test "denies a non-owner before inspecting or mutating the company" do
    invitation = Onboarding::Invite.create!(
      tenant: @org.tenant, email: "khata-viewer@folio.invalid",
      role_code: "viewer", invited_by: @org.user
    )
    viewer = Onboarding::Invite.accept!(
      token: invitation.generate_token_for(:invite), password: "correct-horse-battery"
    )

    assert_raises(Khata::Bridge::NotAuthorized) do
      Khata::Bridge.import!(tenant: @org.tenant, actor: viewer, path: CONSULTING)
    end
    assert_nil KhataImportRun.find_by(tenant_id: @org.tenant.id)
  end

  test "refuses to replace an operational ledger" do
    LedgerEvent.append!(
      tenant_id: @org.tenant.id, actor: @org.user.email_address,
      actor_user_id: @org.user.id, action: "test.event", origin: "test",
      ts: "2026-08-01", payload_str: "{}"
    )

    error = assert_raises(Khata::Bridge::InvalidImport) do
      Khata::Bridge.import!(tenant: @org.tenant, actor: @org.user, path: CONSULTING)
    end
    assert_match(/only before this company has operational records/, error.message)
  end

  test "preserves a tolerated legacy NULL genesis without changing its hash" do
    row = {
      "id" => 1, "prev_hash" => nil, "hash_version" => 2,
      "ts" => "2026-08-01T00:00:00.000Z", "actor" => "legacy-owner",
      "action" => "workspace.created", "ref" => nil,
      "origin" => "bahi", "payload" => "{}"
    }
    row["hash"] = Folio::KhataHash.row_hash(row)

    Posting::PostEntry.ingest_verbatim!(tenant_id: @org.tenant.id, rows: [ row ], replay: false)

    event = LedgerEvent.for_tenant(@org.tenant.id).sole
    assert_nil event.prev_hash
    assert_equal row["hash"], event.hash_hex
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]
  end

  private

  def post_native_journal!
    ledger = Ledger.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    office = Office.find_by!(tenant_id: @org.tenant.id, entity_id: entity.id, code: "PRIMARY")
    codes = Account.where(tenant_id: @org.tenant.id).order(:code).limit(2).pluck(:code)
    Posting::PostEntry.post!(
      tenant_id: @org.tenant.id, actor: @org.user.email_address, actor_user_id: @org.user.id,
      document_date: Date.new(2026, 8, 1), posting_date: Date.new(2026, 8, 1),
      entered_at: Time.utc(2026, 8, 1, 10), fiscal_year: 2026, period_no: 5,
      ledger_id: ledger.id,
      lines: [
        { line_no: 1, account_code: codes.first, ledger_id: ledger.id,
          entity_id: entity.id, office_id: office.id,
          amounts: [ { slot_role: "transaction", currency: "INR",
                       minor_unit_exponent: 2, amount_minor: 100 } ] },
        { line_no: 2, account_code: codes.second, ledger_id: ledger.id,
          entity_id: entity.id, office_id: office.id,
          amounts: [ { slot_role: "transaction", currency: "INR",
                       minor_unit_exponent: 2, amount_minor: -100 } ] }
      ]
    )
  end
end
