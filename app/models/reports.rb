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
  LEDGER_JOIN = "JOIN ledgers report_ledgers ON report_ledgers.tenant_id = entry_lines.tenant_id " \
                "AND report_ledgers.id = entry_lines.ledger_id"
  AMOUNT_JOIN  = "JOIN journal_entry_line_amounts jla ON jla.entry_line_id = entry_lines.id " \
                 "AND jla.slot_role = 'transaction'"
  DEBIT  = "SUM(CASE WHEN jla.amount_minor > 0 THEN jla.amount_minor ELSE 0 END)"
  CREDIT = "SUM(CASE WHEN jla.amount_minor < 0 THEN -jla.amount_minor ELSE 0 END)"
  ACCOUNT_CODE_ORDER = <<~SQL.squish.freeze
    CASE WHEN a.code ~ '^[0-9]+$' THEN 0 ELSE 1 END,
    CASE WHEN a.code ~ '^[0-9]+$' THEN a.code::numeric END,
    a.code
  SQL
  FROZEN_ACCOUNT_NAME = "COALESCE(entry_lines.account_name, a.name)".freeze

  def trial_balance(tenant_id)
    base(tenant_id).group("a.code, #{FROZEN_ACCOUNT_NAME}, a.account_type")
      .order(Arel.sql(ACCOUNT_CODE_ORDER))
      .pluck(Arel.sql("a.code"), Arel.sql(FROZEN_ACCOUNT_NAME), Arel.sql("a.account_type"),
        Arel.sql(DEBIT), Arel.sql(CREDIT))
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

  def aged_open_items(tenant_id, role:, aged_to:)
    OpenItems.call(tenant_id: tenant_id, role: role, aged_to: aged_to)
  end

  def party_ledger(tenant_id, party_id:)
    PartyLedger.call(tenant_id: tenant_id, party_id: party_id)
  end

  def day_book(tenant_id, from_date:, to_date:)
    DayBook.call(tenant_id: tenant_id, from_date: from_date, to_date: to_date)
  end

  def gst_returns(tenant_id, tax_registration_id:, from_date:, to_date:)
    GstReturns.call(
      tenant_id: tenant_id, tax_registration_id: tax_registration_id,
      from_date: from_date, to_date: to_date
    )
  end

  def gstr1_filing(tenant_id, tax_registration_id:, from_date:, to_date:)
    Taxes::India::Gst::Filing.gstr1(
      tenant_id: tenant_id,
      tax_registration_id: tax_registration_id,
      from_date: from_date,
      to_date: to_date
    )
  end

  def gstr3b_filing(tenant_id, tax_registration_id:, from_date:, to_date:, reviewed_itc:)
    Taxes::India::Gst::Filing.gstr3b(
      tenant_id: tenant_id,
      tax_registration_id: tax_registration_id,
      from_date: from_date,
      to_date: to_date,
      reviewed_itc: reviewed_itc
    )
  end

  # Form 26Q — quarterly TDS return (deductor summary + deductee-wise breakup).
  def tds_return_26q(tenant_id, fiscal_year:, quarter:)
    TdsReturn.call(tenant_id: tenant_id, fiscal_year: fiscal_year, quarter: quarter)
  end

  # Form 16A — per-deductee TDS certificate for a quarter.
  def tds_certificate_16a(tenant_id, party_id:, fiscal_year:, quarter:)
    TdsCertificate.call(tenant_id: tenant_id, party_id: party_id, fiscal_year: fiscal_year, quarter: quarter)
  end

  def base(tenant_id)
    EntryLine.where(tenant_id: tenant_id, line_class: "real")
      .joins(ACCOUNT_JOIN).joins(LEDGER_JOIN).joins(AMOUNT_JOIN)
      .where("report_ledgers.posts_to_gl = TRUE")
  end
end
