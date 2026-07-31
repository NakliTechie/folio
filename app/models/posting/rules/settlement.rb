# frozen_string_literal: true

module Posting
  module Rules
    class Settlement
      TYPES = Settlements::BuildDraft::TYPES.freeze

      class << self
        def lock_dependencies!(document)
          pairs = document.document_allocations.order(:target_source_event_id, :target_line_no)
            .pluck(:target_source_event_id, :target_line_no)
          return if pairs.empty?

          predicate = pairs.map { "(source_event_id = ? AND line_no = ?)" }.join(" OR ")
          EntryLine.where(tenant_id: document.tenant_id)
            .where(predicate, *pairs.flatten).order(:id).lock.load
        end

        def validate_document!(document)
          config = TYPES[document.doc_type]
          raise Documents::InvalidDocument, "settlement type is unavailable" unless config

          lines = document.document_lines.to_a
          allocations = document.document_allocations.to_a
          raise Documents::InvalidDocument, "settlement needs one cash or bank line" unless lines.one?
          raise Documents::InvalidDocument, "settlement needs at least one allocation" if allocations.empty?
          unless document.party_id && document.party_snapshot.present? &&
                 document.party_snapshot["id"].to_i == document.party_id
            raise Documents::InvalidDocument, "settlement party snapshot does not match its identity"
          end

          validate_bank_line!(document, lines.first)
          validate_allocations!(document, allocations, config)
        end

        def entry_lines(document)
          validate_document!(document)
          config = TYPES.fetch(document.doc_type)
          ledger = Ledger.find_by!(tenant_id: document.tenant_id, code: "PRIMARY")
          bank_line = document.document_lines.first
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
          [ cash, *party_lines ]
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
        end

        private

        def validate_bank_line!(document, line)
          direction = document.doc_type == "RC" ? 1 : -1
          unless Settlements::BuildDraft::CASH_ACCOUNT_CODES.include?(line.account_code) &&
                 line.amount_minor == direction * document.total_minor &&
                 line.currency == document.currency &&
                 line.minor_unit_exponent == document.minor_unit_exponent && line.item_id.nil?
            raise Documents::InvalidDocument, "settlement cash or bank line was altered"
          end
        end

        def validate_allocations!(document, allocations, config)
          if allocations.map { |allocation| [ allocation.target_source_event_id, allocation.target_line_no ] }.uniq.size !=
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
