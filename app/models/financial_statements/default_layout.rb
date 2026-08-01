# frozen_string_literal: true

module FinancialStatements
  # The conservative starter layout. account_type is used once to seed an explicit assignment;
  # reports themselves use the versioned mapping and never infer presentation from account type.
  module DefaultLayout
    EFFECTIVE_FROM = Date.new(1900, 1, 1)
    ACCOUNT_SECTION = {
      "asset" => "current_assets",
      "liability" => "current_liabilities",
      "equity" => "equity",
      "income" => "operating_revenue",
      "expense" => "operating_expenses"
    }.freeze
    SECTIONS = [
      [ "balance_sheet", "assets", "Assets", "debit", 100, nil ],
      [ "balance_sheet", "current_assets", "Current assets", "debit", 110, "assets" ],
      [ "balance_sheet", "non_current_assets", "Non-current assets", "debit", 120, "assets" ],
      [ "balance_sheet", "equity_liabilities", "Equity and liabilities", "credit", 200, nil ],
      [ "balance_sheet", "equity", "Equity", "credit", 210, "equity_liabilities" ],
      [ "balance_sheet", "current_liabilities", "Current liabilities", "credit", 220, "equity_liabilities" ],
      [ "balance_sheet", "non_current_liabilities", "Non-current liabilities", "credit", 230,
        "equity_liabilities" ],
      [ "profit_and_loss", "income", "Income", "credit", 100, nil ],
      [ "profit_and_loss", "operating_revenue", "Operating revenue", "credit", 110, "income" ],
      [ "profit_and_loss", "other_income", "Other income", "credit", 120, "income" ],
      [ "profit_and_loss", "expenses", "Expenses", "debit", 200, nil ],
      [ "profit_and_loss", "operating_expenses", "Operating expenses", "debit", 210, "expenses" ],
      [ "profit_and_loss", "finance_costs", "Finance costs", "debit", 220, "expenses" ],
      [ "profit_and_loss", "tax_expense", "Tax expense", "debit", 230, "expenses" ]
    ].freeze

    module_function

    def ensure!(tenant)
      version = FinancialStatementVersion.find_or_create_by!(tenant_id: tenant.id, version: 1) do |record|
        record.name = "Default financial statements"
        record.effective_from = EFFECTIVE_FROM
        record.status = "draft"
      end
      sections = {}
      SECTIONS.each do |statement_type, code, label, normal_balance, sort_order, parent_code|
        section = FinancialStatementSection.find_or_create_by!(
          tenant_id: tenant.id, financial_statement_version_id: version.id, code: code
        ) do |record|
          record.statement_type = statement_type
          record.label = label
          record.normal_balance = normal_balance
          record.sort_order = sort_order
        end
        sections[code] = section
        section.update!(parent: sections.fetch(parent_code)) if parent_code && section.parent_id.nil?
      end
      Account.where(tenant_id: tenant.id).find_each { |account| assign!(account, version: version) }
      FinancialStatements::Versions.publish!(version) if version.status == "draft"
      version
    end

    def assign!(account, version: nil)
      versions = version ? [ version ] : FinancialStatementVersion.for_tenant(account.tenant_id).order(:version).to_a
      return if versions.empty?

      assignments = versions.map { |candidate| assign_to_version!(account, candidate) }
      version ? assignments.first : assignments
    end

    def assign_to_version!(account, version)
      unless version.tenant_id == account.tenant_id
        raise ArgumentError, "account and statement version must belong to the same tenant"
      end

      section = version.financial_statement_sections.find_by!(code: ACCOUNT_SECTION.fetch(account.account_type))
      assignment = FinancialStatementAssignment.find_or_initialize_by(
        tenant_id: account.tenant_id,
        financial_statement_version_id: version.id,
        account_id: account.id
      )
      return assignment if assignment.persisted? && assignment.financial_statement_section_id == section.id

      assignment.financial_statement_section = section
      assignment.save!
      assignment
    end
  end
end
