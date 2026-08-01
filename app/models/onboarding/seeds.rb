# frozen_string_literal: true

module Onboarding
  # The starter data a new tenant needs to be usable immediately: a minimal Indian-SMB chart
  # of accounts, document types, and a versioned statement layout. Idempotent.
  module Seeds
    COA = [
      [ "1000", "Cash", "asset" ], [ "1010", "Bank", "asset" ], [ "1200", "Sundry Debtors", "asset" ],
      [ "1190", "Contract Assets (Unbilled Revenue)", "asset" ], [ "1210", "GST Input Credit", "asset" ],
      [ "2000", "Sundry Creditors", "liability" ], [ "2100", "GST Payable", "liability" ],
      [ "2050", "Goods Received Not Invoiced", "liability" ],
      [ "2110", "TDS Payable", "liability" ], [ "2200", "Contract Liabilities (Deferred Revenue)", "liability" ],
      [ "3000", "Capital", "equity" ],
      [ "4000", "Sales", "income" ], [ "4100", "Foreign Exchange Gains", "income" ],
      [ "5000", "Purchases", "expense" ], [ "5100", "Expenses", "expense" ],
      [ "5050", "Inventory Adjustments", "expense" ], [ "5200", "Foreign Exchange Losses", "expense" ],
      [ "1300", "Inventory", "asset" ],
      [ "1400", "Property, Plant and Equipment", "asset" ],
      [ "1410", "Accumulated Depreciation", "asset" ],
      [ "5150", "Depreciation Expense", "expense" ],
      [ "4200", "Gain on Asset Disposal", "income" ],
      [ "5155", "Loss on Asset Disposal", "expense" ]
    ].freeze

    module_function

    def chart_of_accounts!(tenant, jurisdiction_profile: "IN")
      COA.each do |code, name, type|
        name = "Tax Payable" if code == "2100" && jurisdiction_profile != "IN"
        Account.find_or_create_by!(tenant_id: tenant.id, code: code) do |account|
          account.name = name
          account.account_type = type
          account.monetary = %w[1000 1010 1190 1200 2000 2050 2100 2110 2200].include?(code)
        end
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
      DocumentType.find_or_create_by!(tenant_id: tenant.id, code: "PC") do |d|
        d.label = "Supplier Credit Note"; d.posting_rule = "purchase_credit_note"; d.number_prefix = "PC/"
      end
      DocumentType.find_or_create_by!(tenant_id: tenant.id, code: "PD") do |d|
        d.label = "Supplier Debit Note"; d.posting_rule = "purchase_debit_note"; d.number_prefix = "PD/"
      end
      DocumentType.find_or_create_by!(tenant_id: tenant.id, code: "RC") do |d|
        d.label = "Customer Receipt"; d.posting_rule = "settlement"; d.number_prefix = "RC/"
      end
      DocumentType.find_or_create_by!(tenant_id: tenant.id, code: "PY") do |d|
        d.label = "Vendor Payment"; d.posting_rule = "settlement"; d.number_prefix = "PY/"
      end
      DocumentType.find_or_create_by!(tenant_id: tenant.id, code: "RF") do |d|
        d.label = "Open-item Refund"; d.posting_rule = "open_item_refund"; d.number_prefix = "RF/"
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

    def warehouse!(tenant, entity:, office:)
      Warehouse.find_or_create_by!(tenant_id: tenant.id, code: "MAIN") do |record|
        record.entity = entity
        record.office = office
        record.name = "Main warehouse"
        record.warehouse_type = "general"
      end
    end

    def asset_class!(tenant)
      AssetClass.find_or_create_by!(tenant_id: tenant.id, code: "PPE") do |record|
        record.name = "Property, plant and equipment"
        record.apc_account_code = "1400"
        record.accumulated_depreciation_account_code = "1410"
        record.depreciation_expense_account_code = "5150"
        record.gain_account_code = "4200"
        record.loss_account_code = "5155"
        record.default_useful_life_months = 60
      end
    end

    def controlling!(tenant, entity:)
      segment = ControllingSegment.find_or_create_by!(tenant_id: tenant.id, code: "UNASSIGNED") do |record|
        record.name = "Unassigned segment"
      end
      profit = ProfitCenter.find_or_create_by!(tenant_id: tenant.id, code: "UNASSIGNED") do |record|
        record.entity = entity
        record.controlling_segment = segment
        record.name = "Unassigned profit center"
        record.valid_from = Date.new(1900, 1, 1)
      end
      CostCenter.find_or_create_by!(tenant_id: tenant.id, code: "GENERAL") do |record|
        record.entity = entity
        record.profit_center = profit
        record.name = "General overhead"
        record.valid_from = Date.new(1900, 1, 1)
      end
    end
  end
end
