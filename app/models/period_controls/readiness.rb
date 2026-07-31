# frozen_string_literal: true

module PeriodControls
  module Readiness
    module_function

    def call(tenant:, fiscal_year:, period_no:)
      entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      ledger = Ledger.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      fiscal_year = Integer(fiscal_year)
      period_no = Integer(period_no)
      date_range = Calendar.date_range(entity: entity, fiscal_year: fiscal_year, period_no: period_no)
      control = PeriodControl.find_by(Manage.scope_for(tenant, entity, ledger, fiscal_year, period_no))
      entries = Entry.where(
        tenant_id: tenant.id, fiscal_year: fiscal_year, period_no: period_no
      )
      amounts = JournalEntryLineAmount.joins(entry_line: :entry)
        .where(entries: { tenant_id: tenant.id, fiscal_year: fiscal_year, period_no: period_no })
        .where(entry_lines: { line_class: "real" })
        .where(slot_role: "transaction").pluck(:amount_minor)
      debit = amounts.select(&:positive?).sum
      credit = -amounts.select(&:negative?).sum
      chain = LedgerEvent.verify_chain(tenant.id)
      drafts = document_scope(tenant, fiscal_year, period_no, date_range).where(state: %w[draft parked]).count
      unapplied_cash = unapplied_cash_count(tenant, fiscal_year, period_no, date_range)
      reversals = EntryLine.joins(entry: :document).where(
        tenant_id: tenant.id,
        is_negative_posting: true,
        entries: { fiscal_year: fiscal_year, period_no: period_no },
        documents: { doc_type: "SI" }
      ).distinct.count("documents.id")

      {
        entity: { id: entity.id, code: entity.code, name: entity.legal_name },
        ledger: { id: ledger.id, code: ledger.code, name: ledger.name },
        fiscal_year: fiscal_year,
        period_no: period_no,
        period_label: Calendar.label(entity: entity, fiscal_year: fiscal_year, period_no: period_no),
        from_date: date_range&.first,
        to_date: date_range&.last,
        state: control&.state || "open",
        restricted_capability: control&.capability,
        posted_entry_count: entries.count,
        debit_minor: debit,
        credit_minor: credit,
        balanced: debit == credit,
        draft_document_count: drafts,
        unapplied_cash_count: unapplied_cash,
        internal_sales_reversal_count: reversals,
        audit_chain: chain,
        ready: debit == credit && drafts.zero? && unapplied_cash.zero? && chain.fetch(:ok)
      }
    rescue ArgumentError, TypeError
      raise InvalidControl, "fiscal year and period must be valid numbers"
    end

    def document_scope(tenant, fiscal_year, period_no, date_range)
      base = Document.where(tenant_id: tenant.id, fiscal_year: fiscal_year)
      return base.where(doc_type: "OB") if period_no.zero?
      return base.none if period_no > 12

      base.where(posting_date: date_range)
    end

    def unapplied_cash_count(tenant, fiscal_year, period_no, date_range)
      scope = DocumentAllocation.joins(:document).left_outer_joins(:settlement_reallocation).where(
        tenant_id: tenant.id,
        documents: { tenant_id: tenant.id, fiscal_year: fiscal_year, doc_type: %w[RC PY] },
        settlement_reallocations: { id: nil }
      ).where.not(target_reset_event_id: nil)
      return 0 if period_no > 12 || period_no.zero?

      scope.where(documents: { document_date: date_range }).count
    end
  end
end
