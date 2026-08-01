# frozen_string_literal: true

require "digest"

module Khata
  class Bridge
    InvalidImport = Class.new(StandardError)
    NotAuthorized = Class.new(InvalidImport)
    Result = Data.define(:run, :duplicate)

    OPERATIONAL_MODELS = [
      LedgerEvent, DomainEvent, Entry, Document, Party, Item, FixedAsset,
      PurchaseOrder, BankStatementImport, Contract
    ].freeze

    def self.import!(tenant:, actor:, path:, filename: nil)
      new(tenant, actor, path, filename).import!
    end

    def initialize(tenant, actor, path, filename)
      @tenant = tenant
      @actor = actor
      @path = path.to_s
      source_name = File.basename((filename.presence || @path).to_s)
      @filename = source_name.encode("UTF-8", invalid: :replace, undef: :replace)
        .delete("\0").byteslice(0, 255).presence || "books.khata"
    end

    def import!
      authorize!
      size = File.size(@path)
      raise InvalidImport, ".khata file is empty." if size.zero?
      if size > Archive::MAX_ARCHIVE_BYTES
        raise InvalidImport, ".khata file exceeds the 100 MB upload limit."
      end
      archive_sha256 = Digest::SHA256.file(@path).hexdigest
      existing = KhataImportRun.find_by(tenant_id: @tenant.id)
      return Result.new(existing, true) if existing&.archive_sha256 == archive_sha256
      raise InvalidImport, "This company has already imported a different .khata file." if existing

      Archive.open(@path) do |archive|
        ActiveRecord::Base.transaction do
          @tenant.lock!
          reject_nonempty_books!
          entity, office = source_scope!
          adopt_source_identity!(archive, entity, office)
          external_key = create_external_key!(archive)
          Posting::PostEntry.ingest_verbatim!(
            tenant_id: @tenant.id, rows: archive.audit_rows, replay: false,
            external_signing_key_id: external_key&.id
          )
          counts = Import.import_database!(
            database: archive.database, tenant_id: @tenant.id,
            currency: entity.functional_currency, minor_unit_exponent: 2,
            entity_id: entity.id, office_id: office.id,
            ledger_event_id_by_source_entry: entry_event_ids(archive)
          )
          verify_native_parity!(archive)
          chain = LedgerEvent.verify_chain(@tenant.id)
          unless chain[:ok] && chain[:head] == archive.audit_head && chain[:rows] == archive.audit_rows.size
            raise InvalidImport, "Imported audit chain does not reproduce the source chain exactly."
          end

          conformance = archive.conformance.merge(
            "R" => { "ok" => true, "queries" => %w[trial-balance account-type-totals] },
            "identity" => { "warnings" => @identity_warnings }
          )
          event = DomainEvents::Record.call(
            tenant_id: @tenant.id, kind: "khata.imported", actor: @actor.email_address,
            actor_user_id: @actor.id, ref: archive.workspace_id,
            payload: {
              "sourceWorkspaceId" => archive.workspace_id,
              "archiveSha256" => archive_sha256,
              "booksSha256" => archive.books_sha256,
              "auditHead" => archive.audit_head,
              "auditRows" => archive.audit_rows.size,
              "conformance" => conformance
            }
          )
          run = KhataImportRun.create!(
            tenant: @tenant, imported_by: @actor, external_signing_key: external_key,
            domain_event: event, source_workspace_id: archive.workspace_id,
            source_filename: @filename, archive_sha256: archive_sha256,
            books_sha256: archive.books_sha256, source_audit_head: archive.audit_head,
            source_audit_rows: archive.audit_rows.size, source_manifest: archive.manifest,
            import_counts: counts, conformance: conformance
          )
          Result.new(run, false)
        end
      end
    rescue Errno::ENOENT, Errno::EACCES => e
      raise InvalidImport, "Unable to read .khata file: #{e.message}"
    rescue Archive::InvalidArchive, Import::InvalidLineAmount,
           Import::InvalidCurrencyProfile, ActiveRecord::RecordInvalid,
           KeyError, ArgumentError => e
      raise InvalidImport, e.message
    end

    private

    def authorize!
      return if Authorization.permits?(
        user: @actor, tenant_id: @tenant.id, capability: "khata.import"
      )

      raise NotAuthorized, "Only a company owner can import a .khata file."
    end

    def reject_nonempty_books!
      populated = OPERATIONAL_MODELS.filter_map do |model|
        model.model_name.human if model.where(tenant_id: @tenant.id).exists?
      end
      return if populated.empty?

      raise InvalidImport,
        ".khata import is allowed only before this company has operational records " \
        "(found: #{populated.join(', ')})."
    end

    def source_scope!
      entity = Entity.find_by!(tenant_id: @tenant.id, code: "PRIMARY")
      office = Office.find_by!(tenant_id: @tenant.id, entity_id: entity.id, code: "PRIMARY")
      unless entity.jurisdiction_profile == "IN" && entity.functional_currency == "INR"
        raise InvalidImport, ".khata v1 stores Indian books in integer paise; import requires an INR India company."
      end
      [ entity, office ]
    end

    def create_external_key!(archive)
      jwk = archive.manifest.dig("integrity", "signedBy")
      return if jwk.blank?

      ExternalSigningKey.create!(
        tenant: @tenant, source_workspace_id: archive.workspace_id,
        public_key_jwk: jwk, fingerprint: Signatures.fingerprint(jwk)
      )
    end

    def adopt_source_identity!(archive, entity, office)
      company = archive.manifest.fetch("company")
      @identity_warnings = []
      @tenant.update!(name: company.fetch("name"))
      entity.update!(legal_name: company.fetch("name"))
      state_code = company["gstinStateCode"].presence
      if state_code && Taxes::India::StateCodes.valid?(state_code)
        office.update!(country_code: "IN", state_code: state_code)
      end
      %w[GSTIN TAN].each do |kind|
        identifier = company[kind.downcase].presence
        next unless identifier
        if kind == "GSTIN" && !Taxes::India::Gstin.valid?(identifier)
          @identity_warnings <<
            "Source GSTIN failed Folio checksum validation and remains only in immutable source evidence."
          next
        end

        registration = TaxRegistration.create!(
          tenant_id: @tenant.id, entity: entity, kind: kind, identifier: identifier,
          jurisdiction: "IN", valid_from: source_fiscal_year_start(company)
        )
        OfficeTaxRegistration.create!(
          tenant_id: @tenant.id, office: office, tax_registration: registration
        )
      end
    end

    def source_fiscal_year_start(company)
      Date.iso8601(company["fy_start"].to_s)
    rescue Date::Error
      date = @tenant.business_date
      Date.new(date.month >= 4 ? date.year : date.year - 1, 4, 1)
    end

    def verify_native_parity!(archive)
      comparisons = {
        "trial-balance" => [ archive.trial_balance, Reports.trial_balance(@tenant.id) ],
        "account-type-totals" => [ archive.account_type_totals, Reports.account_type_totals(@tenant.id) ]
      }
      mismatch = comparisons.find { |_name, (source, native)| source != native }
      return unless mismatch

      raise InvalidImport, "Native ledger report parity failed for #{mismatch.first}."
    end

    def entry_event_ids(archive)
      events = LedgerEvent.for_tenant(@tenant.id).pluck(:seq, :id).to_h
      archive.audit_rows.filter_map do |row|
        match = row["ref"].to_s.match(/\Aentry:(\d+)\z/)
        next unless row["action"] == "entry.post" && match

        [ match[1].to_i, events.fetch(Integer(row.fetch("id"))) ]
      end.to_h
    end
  end
end
