# frozen_string_literal: true

# B3.5 — the corpus report queries, served from FOLIO's projection (entries/entry_lines/
# journal_entry_line_amounts + accounts), not the .khata adapter. Output shapes match the
# Tier R golden fixtures byte-for-byte once canonicalised.
#
# debit/credit are reconstructed from the signed transaction-slot amount (Folio keeps signed
# minor units, not a debit/credit pair — spec §4): a positive amount is a debit, a negative
# a credit. Exact because every source line is debit-XOR-credit (verified across the corpus).
#
# Only the two ACCOUNT-based reports live here. gst-outward-summary reads Bahi's `invoices`
# and stock-on-hand reads `stock_movements` — domain projections that are Batch 6 (GST) and
# inventory, not the account model. They stay on the adapter until those batches land.
#
# Built with the AR query interface: tenant_id is a bound parameter (.where); the joins and
# the debit/credit aggregates are frozen literals. No user input is ever interpolated into SQL.
module Reports
  module_function

  ACCOUNT_JOIN = "JOIN accounts a ON a.tenant_id = entry_lines.tenant_id AND a.code = entry_lines.account_code"
  AMOUNT_JOIN  = "JOIN journal_entry_line_amounts jla ON jla.entry_line_id = entry_lines.id " \
                 "AND jla.slot_role = 'transaction'"
  DEBIT  = "SUM(CASE WHEN jla.amount_minor > 0 THEN jla.amount_minor ELSE 0 END)"
  CREDIT = "SUM(CASE WHEN jla.amount_minor < 0 THEN -jla.amount_minor ELSE 0 END)"
  ACCOUNT_CODE_ORDER = <<~SQL.squish.freeze
    CASE WHEN a.code ~ '^[0-9]+$' THEN 0 ELSE 1 END,
    CASE WHEN a.code ~ '^[0-9]+$' THEN a.code::numeric END,
    a.code
  SQL

  def trial_balance(tenant_id)
    base(tenant_id).group("a.code, a.name, a.account_type").order(Arel.sql(ACCOUNT_CODE_ORDER))
      .pluck(Arel.sql("a.code"), Arel.sql("a.name"), Arel.sql("a.account_type"), Arel.sql(DEBIT), Arel.sql(CREDIT))
      .map do |code, name, type, debit, credit|
        account_id = code.match?(/\A\d+\z/) ? code.to_i : code
        { "account_id" => account_id, "name" => name, "type" => type,
          "debit" => debit.to_i, "credit" => credit.to_i }
      end
  end

  def account_type_totals(tenant_id)
    base(tenant_id).group("a.account_type").order("a.account_type")
      .pluck(Arel.sql("a.account_type"), Arel.sql(DEBIT), Arel.sql(CREDIT))
      .map { |type, debit, credit| { "type" => type, "debit" => debit.to_i, "credit" => credit.to_i } }
  end

  def profit_and_loss(tenant_id, from_date:, to_date:)
    FinancialStatements::Report.profit_and_loss(
      tenant_id: tenant_id, from_date: from_date, to_date: to_date
    )
  end

  def balance_sheet(tenant_id, as_of:)
    FinancialStatements::Report.balance_sheet(tenant_id: tenant_id, as_of: as_of)
  end

  def base(tenant_id)
    EntryLine.where(tenant_id: tenant_id).joins(ACCOUNT_JOIN).joins(AMOUNT_JOIN)
  end
end
