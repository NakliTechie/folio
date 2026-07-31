# frozen_string_literal: true

module Onboarding
  # The starter data a new tenant needs to be usable immediately: a minimal Indian-SMB chart
  # of accounts, document types, and a versioned statement layout. Idempotent.
  module Seeds
    COA = [
      [ "1000", "Cash", "asset" ], [ "1010", "Bank", "asset" ], [ "1200", "Sundry Debtors", "asset" ],
      [ "1210", "GST Input Credit", "asset" ],
      [ "2000", "Sundry Creditors", "liability" ], [ "2100", "GST Payable", "liability" ],
      [ "3000", "Capital", "equity" ],
      [ "4000", "Sales", "income" ], [ "5000", "Purchases", "expense" ], [ "5100", "Expenses", "expense" ]
    ].freeze

    module_function

    def chart_of_accounts!(tenant, jurisdiction_profile: "IN")
      COA.each do |code, name, type|
        name = "Tax Payable" if code == "2100" && jurisdiction_profile != "IN"
        Account.find_or_create_by!(tenant_id: tenant.id, code: code) { |a| a.name = name; a.account_type = type }
      end
    end

    def document_types!(tenant)
      DocumentType.find_or_create_by!(tenant_id: tenant.id, code: "JV") do |d|
        d.label = "Journal Voucher"; d.posting_rule = "journal_voucher"; d.number_prefix = "JV/"
      end
      DocumentType.find_or_create_by!(tenant_id: tenant.id, code: "OB") do |d|
        d.label = "Opening Balance"; d.posting_rule = "opening_balance"; d.number_prefix = "OB/"
      end
      DocumentType.find_or_create_by!(tenant_id: tenant.id, code: "SI") do |d|
        d.label = "Sales Invoice"; d.posting_rule = "sales_invoice"; d.number_prefix = "SI/"
      end
      DocumentType.find_or_create_by!(tenant_id: tenant.id, code: "CN") do |d|
        d.label = "Credit Note"; d.posting_rule = "credit_note"; d.number_prefix = "CN/"
      end
      DocumentType.find_or_create_by!(tenant_id: tenant.id, code: "PB") do |d|
        d.label = "Purchase Bill"; d.posting_rule = "purchase_bill"; d.number_prefix = "PB/"
      end
    end

    def financial_statements!(tenant)
      FinancialStatements::DefaultLayout.ensure!(tenant)
    end

    def org_spine!(tenant, jurisdiction_profile: "IN", fiscal_year_variant: "IN_APR_MAR")
      entity = Entity.find_or_create_by!(tenant_id: tenant.id, code: "PRIMARY") do |record|
        record.legal_name = tenant.name
        record.functional_currency = tenant.functional_currency
        record.fiscal_year_variant = fiscal_year_variant
        record.jurisdiction_profile = jurisdiction_profile
      end
      office = Office.find_or_create_by!(tenant_id: tenant.id, code: "PRIMARY") do |record|
        record.entity = entity
        record.name = "Head Office"
      end
      ledger = Ledger.find_or_create_by!(tenant_id: tenant.id, code: "PRIMARY") do |record|
        record.name = "Primary Ledger"
        record.kind = "standard"
      end

      { entity: entity, office: office, ledger: ledger }
    end
  end
end
