# frozen_string_literal: true

module Posting
  module Rules
    class Settlement
      TYPES = Settlements::BuildDraft::TYPES.freeze

      class << self
        def lock_dependencies!(document)
          pairs = document.document_allocations.order(:target_source_event_id, :target_ledger_id, :target_line_no)
            .pluck(:target_source_event_id, :target_ledger_id, :target_line_no)
          return if pairs.empty?

          predicate = pairs.map { "(source_event_id = ? AND ledger_id = ? AND line_no = ?)" }.join(" OR ")
          EntryLine.where(tenant_id: document.tenant_id)
            .where(predicate, *pairs.flatten).order(:id).lock.load
        end

        def validate_document!(document)
          config = TYPES[document.doc_type]
          raise Documents::InvalidDocument, "settlement type is unavailable" unless config

          lines = document.document_lines.to_a
          allocations = document.document_allocations.to_a
          tds_line = lines.find { |line| line.account_code == Settlements::BuildDraft::TDS_PAYABLE_ACCOUNT_CODE }
          bank_lines = lines - [ tds_line ].compact
          raise Documents::InvalidDocument, "settlement needs one cash or bank line" unless bank_lines.one?
          if tds_line && document.doc_type != "PY"
            raise Documents::InvalidDocument, "TDS withholding applies only to vendor payments"
          end
          raise Documents::InvalidDocument, "settlement needs at least one allocation" if allocations.empty?
          unless document.party_id && document.party_snapshot.present? &&
                 document.party_snapshot["id"].to_i == document.party_id
            raise Documents::InvalidDocument, "settlement party snapshot does not match its identity"
          end

          validate_bank_line!(document, bank_lines.first, tds_line)
          validate_tds_line!(document, tds_line) if tds_line
          validate_allocations!(document, allocations, config)
        end

        def entry_lines(document)
          validate_document!(document)
          config = TYPES.fetch(document.doc_type)
          ledger = Ledger.find_by!(tenant_id: document.tenant_id, code: "PRIMARY")
          all_lines = document.document_lines.to_a
          tds_line = all_lines.find { |line| line.account_code == Settlements::BuildDraft::TDS_PAYABLE_ACCOUNT_CODE }
          bank_line = (all_lines - [ tds_line ].compact).first
          amount = ->(value) { transaction_amount(document, value) }

          cash = {
            line_no: 1,
            account_code: bank_line.account_code,
            ledger_id: ledger.id,
            entity_id: document.entity_id,
            office_id: document.office_id,
            amounts: [ amount.call(bank_line.amount_minor) ]
          }
          party_direction = document.doc_type == "RC" ? -1 : 1
          party_lines = document.document_allocations.map do |allocation|
            {
              line_no: allocation.line_no + 1,
              account_code: config.fetch(:account_code),
              ledger_id: ledger.id,
              entity_id: document.entity_id,
              office_id: document.office_id,
              party_id: document.party_id,
              party_role: config.fetch(:role),
              open_item: true,
              item_class: "normal",
              assignment: "#{document.doc_type}:#{document.id}:#{allocation.line_no}",
              baseline_date: document.document_date,
              due_date: document.document_date,
              extra: {
                "partySnapshot" => document.party_snapshot,
                "allocationTarget" => allocation.target_snapshot,
                "clearingMode" => allocation.clearing_mode
              },
              amounts: [ amount.call(party_direction * allocation.amount_minor) ]
            }
          end
          entry_lines = [ cash, *party_lines ]
          if tds_line
            # A plain GL credit to TDS Payable — no open_item/party (it is not a clearable
            # sub-ledger item). Placed after every party line so its line_no can't collide.
            entry_lines << {
              line_no: document.document_allocations.size + 2,
              account_code: tds_line.account_code,
              ledger_id: ledger.id,
              entity_id: document.entity_id,
              office_id: document.office_id,
              amounts: [ amount.call(tds_line.amount_minor) ]
            }
          end
          entry_lines
        end

        def after_post!(document:, entry:, actor:)
          document.document_allocations.order(:line_no).each do |allocation|
            target = allocation.target_item
            raise Documents::InvalidDocument, "an allocation target disappeared during posting" unless target

            outstanding = Posting::Clearing.open_amount(target)
            mode = allocation.amount_minor == outstanding ? :full : allocation.clearing_mode.to_sym
            target_event = Posting::Clearing.clear!(
              item: target,
              amount_minor: allocation.amount_minor,
              cleared_on: document.document_date,
              mode: mode,
              clearing_entry: entry,
              actor: actor,
              reason: "#{document.doc_type.downcase} #{document.id} allocation #{allocation.line_no}"
            )
            settlement_line = entry.entry_lines.find_by!(line_no: allocation.line_no + 1)
            settlement_event = Posting::Clearing.clear!(
              item: settlement_line,
              amount_minor: allocation.amount_minor,
              cleared_on: document.document_date,
              mode: :full,
              clearing_entry: entry,
              actor: actor,
              reason: "applied to #{allocation.target_snapshot.fetch("assignment")}"
            )
            allocation.update_columns(
              target_clearing_event_id: target_event.id,
              settlement_clearing_event_id: settlement_event.id,
              updated_at: Time.current
            )
          end
          record_tds_deduction!(document: document, entry: entry)
        end

        # Persist the frozen TDS record from the TDS line's snapshot, inside the posting
        # transaction so the deduction and its ledger entry commit together. No-op when the
        # payment carried no withholding.
        def record_tds_deduction!(document:, entry:)
          tds_line = document.document_lines.find do |line|
            line.account_code == Settlements::BuildDraft::TDS_PAYABLE_ACCOUNT_CODE
          end
          return unless tds_line

          snapshot = tds_line.extra.to_h.fetch("tds")
          TdsDeduction.create!(
            tenant_id: document.tenant_id, party_id: snapshot.fetch("party_id"),
            section: snapshot.fetch("section"), rate_basis_points: snapshot.fetch("rate_basis_points"),
            taxable_minor: snapshot.fetch("taxable_minor"), tds_minor: snapshot.fetch("tds_minor"),
            deduction_date: document.document_date,
            deductee_pan: snapshot["deductee_pan"],
            deductee_name_snapshot: snapshot.fetch("deductee_name_snapshot"),
            source_document_id: document.id, entry_id: entry.id,
            fiscal_year: snapshot.fetch("fiscal_year"), quarter: snapshot.fetch("quarter")
          )
        end

        private

        def validate_bank_line!(document, line, tds_line = nil)
          direction = document.doc_type == "RC" ? 1 : -1
          tds_minor = tds_line ? direction * tds_line.amount_minor : 0
          unless Settlements::BuildDraft::CASH_ACCOUNT_CODES.include?(line.account_code) &&
                 line.amount_minor == direction * (document.total_minor - tds_minor) &&
                 line.currency == document.currency &&
                 line.minor_unit_exponent == document.minor_unit_exponent && line.item_id.nil?
            raise Documents::InvalidDocument, "settlement cash or bank line was altered"
          end
        end

        # The TDS Payable line is a credit (−tds) whose amount must match its own frozen
        # snapshot. PY-only (validate_document! guards that).
        def validate_tds_line!(document, line)
          snapshot = line.extra.to_h["tds"]
          unless snapshot && snapshot["tds_minor"].to_i.positive? &&
                 line.amount_minor == -snapshot["tds_minor"].to_i &&
                 line.currency == document.currency &&
                 line.minor_unit_exponent == document.minor_unit_exponent && line.item_id.nil?
            raise Documents::InvalidDocument, "settlement TDS line was altered"
          end
        end

        def validate_allocations!(document, allocations, config)
          if allocations.map do |allocation|
               [ allocation.target_source_event_id, allocation.target_ledger_id, allocation.target_line_no ]
             end.uniq.size !=
             allocations.size
            raise Documents::InvalidDocument, "each open item may be allocated only once"
          end

          total = allocations.sum(&:amount_minor)
          unless total.positive? && document.subtotal_minor == total && document.tax_minor.zero? &&
                 document.total_minor == total
            raise Documents::InvalidDocument, "settlement total does not match its allocations"
          end

          allocations.each do |allocation|
            target = allocation.target_item
            snapshot = allocation.target_snapshot
            unless Settlements::BuildDraft.eligible_target?(target, config) &&
                   target.party_id == document.party_id &&
                   snapshot["sourceEventId"].to_i == target.source_event_id &&
                   snapshot["ledgerId"].to_i == target.ledger_id &&
                   snapshot["lineNo"].to_i == target.line_no &&
                   snapshot["accountCode"] == target.account_code &&
                   snapshot["partyId"].to_i == target.party_id &&
                   snapshot["partyRole"] == target.party_role
              raise Documents::InvalidDocument,
                "settlement allocation #{allocation.line_no} no longer matches an eligible open item"
            end
            outstanding = Posting::Clearing.open_amount(target)
            unless allocation.amount_minor.positive? && allocation.amount_minor <= outstanding
              raise Documents::InvalidDocument,
                "settlement allocation #{allocation.line_no} exceeds the current outstanding amount"
            end
          end
        end

        def transaction_amount(document, amount_minor)
          {
            slot_role: "transaction", currency: document.currency,
            minor_unit_exponent: document.minor_unit_exponent, amount_minor: amount_minor
          }
        end
      end
    end
  end
end
