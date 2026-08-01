# frozen_string_literal: true

module FinancialStatements
  # Executes a dated statement against posted projections and an explicit presentation version.
  # Amounts are signed once per section's normal balance, then rolled up through the stored tree.
  class Report
    ACCOUNT_JOIN = <<~SQL.squish.freeze
      JOIN accounts statement_accounts
        ON statement_accounts.tenant_id = entry_lines.tenant_id
       AND statement_accounts.code = entry_lines.account_code
    SQL
    ASSIGNMENT_JOIN = <<~SQL.squish.freeze
      JOIN financial_statement_assignments statement_assignments
        ON statement_assignments.account_id = statement_accounts.id
       AND statement_assignments.tenant_id = entry_lines.tenant_id
    SQL
    SECTION_JOIN = <<~SQL.squish.freeze
      JOIN financial_statement_sections statement_sections
        ON statement_sections.id = statement_assignments.financial_statement_section_id
       AND statement_sections.tenant_id = entry_lines.tenant_id
    SQL

    def self.profit_and_loss(tenant_id:, from_date:, to_date:, entity_id: nil)
      new(tenant_id: tenant_id, statement_type: "profit_and_loss",
        from_date: from_date, to_date: to_date, entity_id: entity_id).call
    end

    def self.balance_sheet(tenant_id:, as_of:, entity_id: nil)
      new(tenant_id: tenant_id, statement_type: "balance_sheet", to_date: as_of,
        entity_id: entity_id).call
    end

    def initialize(tenant_id:, statement_type:, to_date:, from_date: nil, entity_id: nil)
      @tenant_id = tenant_id
      @statement_type = statement_type
      @from_date = from_date
      @to_date = to_date
      @legal_book = Reports::LegalBookScope.call(tenant_id: tenant_id, entity_id: entity_id)
    end

    def call
      version = FinancialStatementVersion.resolve!(tenant_id: @tenant_id, on: @to_date)
      sections = version.financial_statement_sections.where(statement_type: @statement_type)
        .order(:sort_order, :id).to_a
      direct = direct_amounts(version, @statement_type, from_date: @from_date)
      synthetic_rows = {}

      if @statement_type == "balance_sheet"
        accumulated_earnings = earnings_amount(version)
        direct[sections.index_by(&:code).fetch("equity").id] += accumulated_earnings
        synthetic_rows["equity"] = {
          code: "accumulated_earnings", label: "Accumulated earnings",
          amount_minor: accumulated_earnings
        }
      end

      totals = rollup(sections, direct)
      rows = flatten(sections, totals, synthetic_rows)
      result = {
        statement_type: @statement_type,
        version: {
          id: version.id, name: version.name, version: version.version,
          effective_from: version.effective_from
        },
        from_date: @from_date,
        to_date: @to_date,
        entity: {
          id: @legal_book.entity.id, code: @legal_book.entity.code,
          legal_name: @legal_book.entity.legal_name
        },
        currency: @legal_book.currency,
        rows: rows,
        unmapped_accounts: unmapped_accounts(version)
      }
      result.merge!(summary(sections, totals))
      result
    end

    private

    def base_scope(from_date:)
      scope = @legal_book.lines.joins(:entry)
        .where("entries.posting_date <= ?", @to_date)
      scope = scope.where("entries.posting_date >= ?", from_date) if from_date
      scope
    end

    def mapped_scope(version, statement_type, from_date:)
      base_scope(from_date: from_date)
        .joins(ACCOUNT_JOIN).joins(ASSIGNMENT_JOIN).joins(SECTION_JOIN)
        .where("statement_assignments.financial_statement_version_id = ?", version.id)
        .where("statement_sections.statement_type = ?", statement_type)
    end

    def direct_amounts(version, statement_type, from_date:)
      scope = mapped_scope(version, statement_type, from_date: from_date)
      scope = scope.where.not(entries: { period_no: 0 }) if statement_type == "profit_and_loss"
      rows = scope
        .group("statement_sections.id", "statement_sections.normal_balance")
        .pluck(
          Arel.sql("statement_sections.id"),
          Arel.sql("statement_sections.normal_balance"),
          Arel.sql("SUM(legal_report_amounts.amount_minor)")
        )
      rows.each_with_object(Hash.new(0)) do |(section_id, normal_balance, signed_amount), amounts|
        amounts[section_id] = normal_balance == "credit" ? -signed_amount.to_i : signed_amount.to_i
      end
    end

    # P&L accounts remain open until a closing entry moves them to equity. Including their
    # all-time net as accumulated earnings keeps Assets = Equity + Liabilities before close.
    def earnings_amount(version)
      sections = version.financial_statement_sections.where(statement_type: "profit_and_loss").to_a
      amounts = direct_amounts(version, "profit_and_loss", from_date: nil)
      totals = rollup(sections, amounts)
      by_code = sections.index_by(&:code)
      totals.fetch(by_code.fetch("income").id, 0) - totals.fetch(by_code.fetch("expenses").id, 0)
    end

    def rollup(sections, direct)
      children = sections.group_by(&:parent_id)
      totals = {}
      calculate = lambda do |section|
        totals[section.id] = direct.fetch(section.id, 0) +
          Array(children[section.id]).sum { |child| calculate.call(child) }
      end
      Array(children[nil]).each { |root| calculate.call(root) }
      totals
    end

    def flatten(sections, totals, synthetic_rows)
      children = sections.group_by(&:parent_id)
      walk = lambda do |section, depth|
        row = {
          code: section.code,
          label: section.label,
          depth: depth,
          amount_minor: totals.fetch(section.id, 0),
          total: children[section.id].present?
        }
        nested = Array(children[section.id]).flat_map { |child| walk.call(child, depth + 1) }
        synthetic = synthetic_rows[section.code]
        synthetic_row = synthetic ? [ synthetic.merge(depth: depth + 1, total: false) ] : []
        [ row, *nested, *synthetic_row ]
      end
      Array(children[nil]).flat_map { |root| walk.call(root, 0) }
    end

    def unmapped_accounts(version)
      relevant_types = @statement_type == "balance_sheet" ? %w[asset liability equity] : %w[income expense]
      posted_codes = base_scope(from_date: @from_date).distinct.pluck(:account_code)
      return [] if posted_codes.empty?

      mapped_ids = FinancialStatementAssignment
        .joins(:financial_statement_section)
        .where(tenant_id: @tenant_id, financial_statement_version_id: version.id)
        .where(financial_statement_sections: { statement_type: @statement_type })
        .select(:account_id)
      Account.where(tenant_id: @tenant_id, account_type: relevant_types, code: posted_codes)
        .where.not(id: mapped_ids).order(:code).pluck(:code, :name)
        .map { |code, name| { code: code, name: name } }
    end

    def summary(sections, totals)
      by_code = sections.index_by(&:code)
      if @statement_type == "profit_and_loss"
        income = totals.fetch(by_code.fetch("income").id, 0)
        expenses = totals.fetch(by_code.fetch("expenses").id, 0)
        { income_minor: income, expenses_minor: expenses, net_income_minor: income - expenses }
      else
        assets = totals.fetch(by_code.fetch("assets").id, 0)
        equity_liabilities = totals.fetch(by_code.fetch("equity_liabilities").id, 0)
        { assets_minor: assets, equity_liabilities_minor: equity_liabilities,
          difference_minor: assets - equity_liabilities }
      end
    end
  end
end
