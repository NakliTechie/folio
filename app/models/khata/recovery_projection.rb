# frozen_string_literal: true

require "digest"
require "time"

module Khata
  class RecoveryProjection
    InvalidSnapshot = Class.new(StandardError)
    SCHEMA_VERSION = 1

    def self.capture!(run)
      new(run).capture!
    end

    def self.restore!(run)
      new(run).restore!
    end

    def initialize(run)
      @run = run
      @tenant_id = run.tenant_id
    end

    def capture!
      return run.recovery_snapshot if run.recovery_snapshot

      projection = build_projection
      payload = Folio::KhataHash.canonical_payload(projection)
      snapshot = KhataRecoverySnapshot.create!(
        tenant_id: tenant_id, khata_import_run: run, schema_version: SCHEMA_VERSION,
        projection: projection, projection_sha256: Digest::SHA256.hexdigest(payload)
      )
      run.association(:recovery_snapshot).reset
      snapshot
    end

    def restore!
      snapshot = run.recovery_snapshot
      raise InvalidSnapshot, "Imported .khata books have no governed recovery snapshot." unless snapshot
      unless snapshot.schema_version == SCHEMA_VERSION && secure_digest?(snapshot)
        raise InvalidSnapshot, "Imported .khata recovery evidence failed its integrity check."
      end

      maps = target_maps
      snapshot.projection.fetch("entries").each do |source|
        event = maps.fetch(:events).fetch(Integer(source.fetch("ledgerEventSeq")))
        entry = Entry.create!(
          tenant_id: tenant_id, ledger_event_id: event.id,
          document_date: source.fetch("documentDate"), posting_date: source.fetch("postingDate"),
          entered_at: Time.iso8601(source.fetch("enteredAt")),
          fiscal_year: source.fetch("fiscalYear"), period_no: source.fetch("periodNo")
        )
        source.fetch("lines").each do |line_source|
          restore_line!(entry, line_source, maps)
        end
      end
      verify_counts!
    rescue KeyError, ArgumentError, TypeError, ActiveRecord::RecordInvalid => e
      raise InvalidSnapshot, "Imported .khata recovery evidence is not replayable: #{e.message}"
    end

    private

    attr_reader :run, :tenant_id

    def build_projection
      events = LedgerEvent.for_tenant(tenant_id)
        .where(seq: 1..run.source_audit_rows).pluck(:id, :seq).to_h
      scope = Entry.where(tenant_id: tenant_id, ledger_event_id: events.keys)
        .includes(entry_lines: [ :amounts, :ledger ]).order(:posting_date, :id)
      entries = scope.map { |entry| serialize_entry(entry, events) }
      expected = run.import_counts.fetch("entries", run.import_counts[:entries]).to_i
      unless entries.size == expected
        raise InvalidSnapshot,
          "Imported projection contains #{entries.size} source entries; expected #{expected}."
      end
      { "schemaVersion" => SCHEMA_VERSION, "entries" => entries,
        "counts" => normalized_counts(entries) }
    end

    def serialize_entry(entry, event_seq_by_id)
      {
        "ledgerEventSeq" => event_seq_by_id.fetch(entry.ledger_event_id),
        "documentDate" => entry.document_date.iso8601,
        "postingDate" => entry.posting_date.iso8601,
        "enteredAt" => entry.entered_at.utc.iso8601(6),
        "fiscalYear" => entry.fiscal_year,
        "periodNo" => entry.period_no,
        "lines" => entry.entry_lines.sort_by { |line| [ line.line_no, line.id ] }
          .map { |line| serialize_line(line, event_seq_by_id) }
      }
    end

    def serialize_line(line, event_seq_by_id)
      ensure_portable_line!(line)
      {
        "lineNo" => line.line_no, "accountCode" => line.account_code,
        "accountName" => line.account_name,
        "ledgerCode" => line.ledger.code,
        "entityCode" => Entity.find(line.entity_id).code,
        "officeCode" => Office.find(line.office_id).code,
        "sourceEventSeq" => event_seq_by_id.fetch(line.source_event_id),
        "lineClass" => line.line_class, "postingLayer" => line.posting_layer,
        "valueDate" => line.value_date&.iso8601,
        "amounts" => line.amounts.sort_by(&:slot_role).map do |amount|
          {
            "slotRole" => amount.slot_role, "currency" => amount.currency,
            "minorUnitExponent" => amount.minor_unit_exponent,
            "amountMinor" => amount.amount_minor,
            "rate" => amount.rate&.to_s, "rateDate" => amount.rate_date&.iso8601,
            "rateSource" => amount.rate_source, "rateBasis" => amount.rate_basis
          }.compact
        end
      }.compact
    end

    def ensure_portable_line!(line)
      unsupported = %i[
        tax_registration_id cost_object_id profit_center_id segment_id functional_area_id
        partner_entity_id partner_profit_center_id partner_segment_id partner_cost_object_id
        intercompany_transaction_id party_id item_id warehouse_id fixed_asset_id
        cleared_by_entry_id reconciliation_gl_account_id split_source_line_id liquidity_item_id
        residual_of_line_id
      ].any? { |field| line.public_send(field).present? }
      if unsupported || line.open_item? || line.cleared_on.present? || line.cleared_amount_minor.nonzero?
        raise InvalidSnapshot, "Imported .khata line #{line.id} contains non-portable projection state."
      end
      raise InvalidSnapshot, "Imported .khata line #{line.id} has no stable source event." if line.source_event_id.blank?
    end

    def restore_line!(entry, source, maps)
      source_event = maps.fetch(:events).fetch(Integer(source.fetch("sourceEventSeq")))
      line = EntryLine.create!(
        tenant_id: tenant_id, entry: entry, source_event_id: source_event.id,
        line_no: source.fetch("lineNo"), account_code: source.fetch("accountCode"),
        account_name: source["accountName"],
        ledger_id: maps.fetch(:ledgers).fetch(source.fetch("ledgerCode")),
        entity_id: maps.fetch(:entities).fetch(source.fetch("entityCode")),
        office_id: maps.fetch(:offices).fetch(source.fetch("officeCode")),
        line_class: source.fetch("lineClass", "real"),
        posting_layer: source.fetch("postingLayer", "00"), value_date: source["valueDate"]
      )
      source.fetch("amounts").each do |amount|
        JournalEntryLineAmount.create!(
          tenant_id: tenant_id, entry_line: line,
          slot_role: amount.fetch("slotRole"), currency: amount.fetch("currency"),
          minor_unit_exponent: amount.fetch("minorUnitExponent"),
          amount_minor: amount.fetch("amountMinor"), rate: amount["rate"],
          rate_date: amount["rateDate"], rate_source: amount["rateSource"],
          rate_basis: amount["rateBasis"]
        )
      end
    end

    def target_maps
      {
        events: LedgerEvent.for_tenant(tenant_id).where(seq: 1..run.source_audit_rows)
          .index_by(&:seq),
        ledgers: Ledger.where(tenant_id: tenant_id).pluck(:code, :id).to_h,
        entities: Entity.where(tenant_id: tenant_id).pluck(:code, :id).to_h,
        offices: Office.where(tenant_id: tenant_id).pluck(:code, :id).to_h
      }
    end

    def secure_digest?(snapshot)
      actual = Digest::SHA256.hexdigest(
        Folio::KhataHash.canonical_payload(snapshot.projection)
      )
      ActiveSupport::SecurityUtils.secure_compare(actual, snapshot.projection_sha256)
    end

    def normalized_counts(entries)
      { "entries" => entries.size,
        "lines" => entries.sum { |entry| entry.fetch("lines").size },
        "amounts" => entries.sum do |entry|
          entry.fetch("lines").sum { |line| line.fetch("amounts").size }
        end }
    end

    def verify_counts!
      expected = run.recovery_snapshot.projection.fetch("counts")
      event_ids = LedgerEvent.for_tenant(tenant_id).where(seq: 1..run.source_audit_rows).select(:id)
      entries = Entry.where(tenant_id: tenant_id, ledger_event_id: event_ids)
      lines = EntryLine.where(tenant_id: tenant_id, entry_id: entries.select(:id))
      actual = {
        "entries" => entries.count,
        "lines" => lines.count,
        "amounts" => JournalEntryLineAmount.where(
          tenant_id: tenant_id, entry_line_id: lines.select(:id)
        ).count
      }
      raise InvalidSnapshot, "Imported .khata recovery counts do not match." unless actual == expected
    end
  end
end
