# frozen_string_literal: true

module Banking
  module Reconcile
    module_function

    def auto_match!(statement:, actor:)
      assert_open!(statement)
      matched = 0
      BankStatementImport.transaction do
        LedgerEvent.acquire_tenant_lock!(statement.tenant_id)
        statement.lock!
        statement.bank_statement_lines.where(status: "unmatched").in_statement_order.each do |line|
          candidates = candidates_for(line).limit(2).to_a
          next unless candidates.one?

          match!(line: line, entry_line: candidates.first, actor: actor, method: "exact")
          matched += 1
        end
        append_match_event(statement, actor, "bank_statement.auto_matched", matched)
      end
      matched
    end

    def manual_match!(line:, entry_line:, actor:)
      statement = line.bank_statement_import
      assert_open!(statement)
      BankStatementLine.transaction do
        LedgerEvent.acquire_tenant_lock!(statement.tenant_id)
        statement.lock!
        line.lock!
        unless candidate_eligible?(line, entry_line, date_window: nil)
          raise InvalidStatement, "the selected ledger line does not match this bank amount, account, or currency"
        end
        match!(line: line, entry_line: entry_line, actor: actor, method: "manual")
        append_match_event(statement, actor, "bank_statement.line_matched", 1, line: line)
        line
      end
    end

    def ignore!(line:, actor:, reason:)
      assert_open!(line.bank_statement_import)
      BankStatementLine.transaction do
        LedgerEvent.acquire_tenant_lock!(line.tenant_id)
        line.bank_statement_import.lock!
        line.lock!
        raise InvalidStatement, "only an unmatched line can be ignored" unless line.status == "unmatched"

        line.update!(status: "ignored", ignore_reason: reason.to_s.strip)
        append_match_event(line.bank_statement_import, actor, "bank_statement.line_ignored", 1, line: line)
        line
      end
    end

    def finalize!(statement:, actor:)
      BankStatementImport.transaction do
        LedgerEvent.acquire_tenant_lock!(statement.tenant_id)
        statement.lock!
        assert_open!(statement)
        unresolved = statement.bank_statement_lines.where(status: "unmatched").count
        raise InvalidStatement, "#{unresolved} statement lines are still unmatched" if unresolved.positive?

        movement = statement.bank_statement_lines.sum(:amount_minor)
        expected = statement.closing_balance_minor - statement.opening_balance_minor
        unless movement == expected
          raise InvalidStatement,
            "statement movement #{movement} does not reconcile opening and closing balances (expected #{expected})"
        end
        event = DomainEvents::Record.call(
          tenant_id: statement.tenant_id, office_id: statement.office_id,
          kind: "bank_statement.reconciled", actor: "u:#{actor.id}", actor_user_id: actor.id,
          ref: statement.source_sha256,
          payload: {
            "statementImportId" => statement.id,
            "matchedCount" => statement.bank_statement_lines.where(status: "matched").count,
            "ignoredCount" => statement.bank_statement_lines.where(status: "ignored").count,
            "openingBalanceMinor" => statement.opening_balance_minor,
            "closingBalanceMinor" => statement.closing_balance_minor
          }
        )
        statement.update!(
          status: "reconciled", reconciled_domain_event: event, reconciled_at: Time.current
        )
        statement
      end
    end

    def candidates_for(line)
      statement = line.bank_statement_import
      used = BankStatementLine.where(tenant_id: line.tenant_id, status: "matched")
        .where.not(matched_ledger_event_id: nil)
        .pluck(:matched_ledger_event_id, :matched_entry_line_no)
      scope = EntryLine.joins(:entry, :amounts).where(
        tenant_id: line.tenant_id, account_code: statement.bank_account_code,
        journal_entry_line_amounts: {
          slot_role: "transaction", currency: line.currency, amount_minor: line.amount_minor
        },
        entries: { posting_date: (line.booking_date - 3.days)..(line.booking_date + 3.days) }
      )
      used.reduce(scope) do |relation, (event_id, line_no)|
        relation.where.not(source_event_id: event_id, line_no: line_no)
      end.order("entries.posting_date": :asc, "entry_lines.id": :asc)
    end

    def candidate_eligible?(line, entry_line, date_window:)
      statement = line.bank_statement_import
      amount = entry_line.amounts.find_by(slot_role: "transaction", currency: line.currency)
      return false unless entry_line.tenant_id == line.tenant_id &&
        entry_line.account_code == statement.bank_account_code && amount&.amount_minor == line.amount_minor
      return false if BankStatementLine.where(
        tenant_id: line.tenant_id, matched_ledger_event_id: entry_line.source_event_id,
        matched_entry_line_no: entry_line.line_no
      ).where.not(id: line.id).exists?
      return true unless date_window

      entry_line.entry.posting_date.between?(*date_window)
    end

    def match!(line:, entry_line:, actor:, method:)
      raise InvalidStatement, "only an unmatched line can be matched" unless line.status == "unmatched"

      line.update!(
        status: "matched", match_method: method,
        matched_ledger_event_id: entry_line.source_event_id,
        matched_entry_line_no: entry_line.line_no,
        matched_by: actor, matched_at: Time.current
      )
    end

    def append_match_event(statement, actor, kind, count, line: nil)
      return if count.zero?

      DomainEvents::Record.call(
        tenant_id: statement.tenant_id, office_id: statement.office_id,
        kind: kind, actor: "u:#{actor.id}", actor_user_id: actor.id,
        ref: statement.source_sha256,
        payload: {
          "statementImportId" => statement.id, "matchedCount" => count,
          "statementLineNo" => line&.line_no,
          "matchedLedgerEventId" => line&.matched_ledger_event_id,
          "matchedEntryLineNo" => line&.matched_entry_line_no
        }.compact
      )
    end

    def assert_open!(statement)
      raise InvalidStatement, "the bank statement is already reconciled" unless statement.status == "imported"
    end
  end
end
