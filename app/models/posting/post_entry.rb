# frozen_string_literal: true

require "json"

# The single posting entry point (spec §1 balance, §9 fat events, §11 provenance,
# §13 authority; decisions D1, D11, D13). Two paths that share one projection builder:
#
#   post!(draft)   → assert balance → build a FAT, D15-compliant payload → append! the
#                    event → replay!(event) to build the projection.
#   replay!(event) → build entries/entry_lines/amounts PURELY from a stored event's
#                    payload, with NO config or master-data lookup.
#
# Because post! projects by calling replay!, the post and replay projections are identical
# BY CONSTRUCTION — replay is provably a pure function of the payload, which is the whole
# fat-events guarantee (§9): "the projection you rebuild is the ledger you posted."
#
# Balance is asserted per (ledger, slot_role, currency) — NEVER globally. A global Dr=Cr
# check is not a weaker version of this; it is a wrong one (spec §1): the technical-
# clearing pattern needs an entry whose whole does not balance while each ledger slice does.
#
# The balance check and payload builders are pure (no DB), so the accounting core is unit-
# testable against the standard without Rails, per the PORO intent.
module Posting
  # UnbalancedError lives in its own file (unbalanced_error.rb) so Zeitwerk can autoload it
  # independently — co-locating it here made `Posting::UnbalancedError` unresolvable unless
  # `Posting::PostEntry` had already been loaded, an order-dependent CI flake.

  class PostEntry
    ENGINE_VERSION = "b3.2"

    # ---- pure: balance per (ledger, slot_role, currency) -----------------------------
    # `lines` is an array of hashes each with :ledger_id and :amounts (each amount a hash
    # with :slot_role, :currency, :amount_minor). Returns a Hash of offending
    # [ledger_id, slot_role, currency] => non-zero signed sum (empty when balanced).
    def self.balance_offenders(lines)
      sums = Hash.new(0)
      lines.each do |line|
        line.fetch(:amounts).each do |amt|
          key = [ line.fetch(:ledger_id), amt.fetch(:slot_role), amt.fetch(:currency) ]
          sums[key] += Integer(amt.fetch(:amount_minor))
        end
      end
      sums.reject { |_k, v| v.zero? }
    end

    def self.balanced?(lines)
      balance_offenders(lines).empty?
    end

    # ---- period control (spec §6): enforced here, on the single posting entry point, at
    # post time only. Replay never re-checks — a historical event reproduces regardless of
    # the period's CURRENT state. A closed period rejects; a restricted one needs the
    # capability; a special period (13-16) is just another period_no, open unless controlled.
    def self.assert_period_open!(draft, lines)
      fy = draft.fetch(:fiscal_year)
      pno = draft.fetch(:period_no)
      caps = Array(draft[:capabilities])
      lines.each do |l|
        state, capability = PeriodControl.resolve(
          tenant_id: draft.fetch(:tenant_id), entity_id: l.fetch(:entity_id), ledger_id: l.fetch(:ledger_id),
          account_class: account_class_for(l), fiscal_year: fy, period_no: pno
        )
        case state
        when "closed"
          raise PeriodClosedError, "period #{fy}/#{pno} is closed for ledger #{l[:ledger_id]} (#{account_class_for(l)})"
        when "restricted"
          unless capability && (caps.include?("*") || caps.include?(capability))
            raise PeriodRestrictedError, "period #{fy}/#{pno} is restricted; capability '#{capability}' required"
          end
        end
      end
    end

    def self.account_class_for(line)
      return line[:account_class] if line[:account_class]

      case line[:party_role]
      when "customer" then "AR"
      when "vendor" then "AP"
      else "GL"
      end
    end

    # ---- POST path -------------------------------------------------------------------
    def self.post!(draft)
      lines = normalize_lines(draft)
      offenders = balance_offenders(lines)
      raise UnbalancedError, offenders unless offenders.empty?
      assert_period_open!(draft, lines)

      ActiveRecord::Base.transaction do
        payload_str = Folio::KhataHash.canonical_payload(build_payload(draft, lines))
        event = LedgerEvent.append!(
          tenant_id: draft.fetch(:tenant_id),
          actor: draft.fetch(:actor),
          action: "entry.posted",
          origin: draft.fetch(:origin, "folio"),
          ts: draft.fetch(:posting_date).to_s,
          payload_str: payload_str,
          office_id: draft[:office_id]
        )
        replay!(event)
      end
    end

    # ---- REPLAY path: PURE projection from a stored fat event ------------------------
    # Reads ONLY event.payload — no config, no master-data, no as_of lookup. Returns the
    # projected Entry, or nil for a non-fat event (e.g. a thin .khata corpus summary),
    # which is stored verbatim on the chain but carries no line detail to project.
    def self.replay!(event)
      data = JSON.parse(event.payload)
      return nil unless data.is_a?(Hash) && data["entry"].is_a?(Hash) && data["lines"].is_a?(Array)

      e = data["entry"]
      entry = Entry.create!(
        tenant_id: event.tenant_id, ledger_event_id: event.id, document_id: e["documentId"],
        document_date: e["documentDate"], posting_date: e["postingDate"], entered_at: e["enteredAt"],
        fiscal_year: e["fiscalYear"], period_no: e["periodNo"],
        role_template_id: data.dig("provenance", "authorizedUnder", "roleTemplateId"),
        posting_limit_id: data.dig("provenance", "authorizedUnder", "postingLimitId")
      )

      data["lines"].each do |l|
        line = EntryLine.create!(
          tenant_id: event.tenant_id, entry_id: entry.id, source_event_id: event.id,
          line_no: l["lineNo"], account_code: l["accountCode"], ledger_id: l["ledgerId"],
          entity_id: l["entityId"], office_id: l["officeId"], tax_registration_id: l["taxRegistrationId"],
          cost_object_type: l["costObjectType"], cost_object_id: l["costObjectId"],
          profit_center_id: l["profitCenterId"], segment_id: l["segmentId"],
          functional_area_id: l["functionalAreaId"],
          line_class: l["lineClass"] || "real", posting_layer: l["postingLayer"] || "00",
          partner_entity_id: l["partnerEntityId"], intercompany_transaction_id: l["intercompanyTransactionId"],
          party_id: l["partyId"], party_role: l["partyRole"],
          item_id: l["itemId"], quantity: l["quantity"], uom: l["uom"], hsn_sac_code: l["hsnSacCode"],
          tax_component: l["taxComponent"], tax_rate_basis_points: l["taxRateBasisPoints"],
          taxable_amount_minor: l["taxableAmountMinor"],
          movement_type: l["movementType"], value_date: l["valueDate"],
          open_item: l["openItem"] || false, item_class: l["itemClass"],
          assignment: l["assignment"], baseline_date: l["baselineDate"], due_date: l["dueDate"],
          is_negative_posting: l["isNegativePosting"] || false, extra: l["extra"]
        )
        Array(l["amounts"]).each do |a|
          JournalEntryLineAmount.create!(
            tenant_id: event.tenant_id, entry_line_id: line.id,
            slot_role: a["slotRole"], currency: a["currency"],
            minor_unit_exponent: a["minorUnitExponent"], amount_minor: a["amountMinor"],
            rate: a["rate"], rate_date: a["rateDate"], rate_source: a["rateSource"], rate_basis: a["rateBasis"]
          )
        end
      end
      entry
    end

    # ---- REPLAY INGESTION (the M4-bridge shape) --------------------------------------
    # Store an existing chain verbatim (preserving each row's own prev_hash/hash so the
    # chain reproduces byte-for-byte), then replay! any fat events into projections.
    # `rows` are .khata audit_log rows (column names as in the corpus).
    def self.ingest_verbatim!(tenant_id:, rows:)
      now = Time.now.utc
      LedgerEvent.insert_all!(
        rows.each_with_index.map do |r, i|
          {
            tenant_id: tenant_id, seq: i + 1,
            prev_hash: r["prev_hash"].to_s, hash_hex: r["hash"],
            hash_version: r["hash_version"] || Folio::KhataHash::HASH_VERSION,
            ts: r["ts"], actor: r["actor"], action: r["action"],
            ref: r["ref"], origin: r["origin"], payload: r["payload"], recorded_at: now
          }
        end
      )
      LedgerEvent.for_tenant(tenant_id).in_order.each { |ev| replay!(ev) }
    end

    # ---- pure payload builders (no DB) -----------------------------------------------

    # Fills line-level defaults so the payload is self-describing on replay.
    def self.normalize_lines(draft)
      default_ledger = draft[:ledger_id]
      draft.fetch(:lines).map do |l|
        l = l.dup
        l[:ledger_id]    ||= default_ledger
        l[:line_class]   ||= "real"
        l[:posting_layer] ||= "00"
        l
      end
    end

    def self.build_payload(draft, lines = normalize_lines(draft))
      deep_compact(
        "entry" => {
          "documentDate" => draft.fetch(:document_date).to_s,
          "postingDate"  => draft.fetch(:posting_date).to_s,
          "enteredAt"    => draft.fetch(:entered_at).iso8601,
          "fiscalYear"   => draft.fetch(:fiscal_year),
          "periodNo"     => draft.fetch(:period_no),
          "documentId"   => draft.dig(:document, :id)
        },
        "lines" => lines.map { |l| line_payload(l) },
        "provenance" => {
          "configVersions" => draft[:config_versions],
          "engineVersion"  => ENGINE_VERSION,
          "authorizedUnder" => {
            "roleTemplateId" => draft.dig(:authority, :role_template_id),
            "postingLimitId" => draft.dig(:authority, :posting_limit_id)
          }
        }
      )
    end

    def self.line_payload(l)
      {
        "lineNo" => l.fetch(:line_no), "accountCode" => l.fetch(:account_code),
        "ledgerId" => l.fetch(:ledger_id), "entityId" => l.fetch(:entity_id),
        "officeId" => l.fetch(:office_id), "taxRegistrationId" => l[:tax_registration_id],
        "costObjectType" => l[:cost_object_type], "costObjectId" => l[:cost_object_id],
        "profitCenterId" => l[:profit_center_id], "segmentId" => l[:segment_id],
        "functionalAreaId" => l[:functional_area_id],
        "lineClass" => l[:line_class], "postingLayer" => l[:posting_layer],
        "partnerEntityId" => l[:partner_entity_id], "intercompanyTransactionId" => l[:intercompany_transaction_id],
        "partyId" => l[:party_id], "partyRole" => l[:party_role],
        "itemId" => l[:item_id], "quantity" => l[:quantity]&.to_s, "uom" => l[:uom],
        "hsnSacCode" => l[:hsn_sac_code], "taxComponent" => l[:tax_component],
        "taxRateBasisPoints" => l[:tax_rate_basis_points],
        "taxableAmountMinor" => l[:taxable_amount_minor],
        "movementType" => l[:movement_type], "valueDate" => l[:value_date]&.to_s,
        # booleans: present only in their non-default (true) state, so replay defaults false.
        "openItem" => (true if l[:open_item]), "isNegativePosting" => (true if l[:is_negative_posting]),
        "itemClass" => l[:item_class], "assignment" => l[:assignment],
        "baselineDate" => l[:baseline_date]&.to_s, "dueDate" => l[:due_date]&.to_s,
        "extra" => (l[:extra].presence),
        "amounts" => Array(l.fetch(:amounts)).map { |a| amount_payload(a) }
      }
    end

    def self.amount_payload(a)
      {
        "slotRole" => a.fetch(:slot_role), "currency" => a.fetch(:currency),
        "minorUnitExponent" => Integer(a.fetch(:minor_unit_exponent)),
        "amountMinor" => Integer(a.fetch(:amount_minor)),
        # rate is the one decimal — serialise as a STRING to avoid float byte-drift.
        "rate" => a[:rate]&.to_s, "rateDate" => a[:rate_date]&.to_s,
        "rateSource" => a[:rate_source], "rateBasis" => a[:rate_basis]
      }
    end

    # D15: omit absent keys, never emit null. Drops nil values and any hash that empties
    # out, recursively; keeps array elements. This is what keeps the preimage stable —
    # the canonical serialiser walks present keys, so a null-valued key would change bytes.
    def self.deep_compact(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), h|
          cv = deep_compact(v)
          next if cv.nil?
          next if cv.is_a?(Hash) && cv.empty?
          h[k] = cv
        end
      when Array
        obj.map { |e| deep_compact(e) }
      else
        obj
      end
    end
  end
end
