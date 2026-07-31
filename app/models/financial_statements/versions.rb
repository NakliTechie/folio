# frozen_string_literal: true

module FinancialStatements
  # Draft/clone/publish lifecycle for statement presentation. Published configuration is never
  # edited in place; a new effective-dated version replaces it for future report dates.
  module Versions
    REQUIRED_CODES = %w[assets equity_liabilities equity income expenses].freeze

    module_function

    def clone!(source:, effective_from:, name: nil)
      FinancialStatementVersion.transaction do
        Tenant.lock.find(source.tenant_id)
        next_version = FinancialStatementVersion.for_tenant(source.tenant_id).maximum(:version).to_i + 1
        draft = FinancialStatementVersion.create!(
          tenant_id: source.tenant_id,
          name: name.presence || source.name,
          version: next_version,
          effective_from: effective_from,
          status: "draft"
        )
        section_map = {}
        source.financial_statement_sections.order(:sort_order, :id).each do |section|
          copy = draft.financial_statement_sections.create!(
            tenant_id: source.tenant_id,
            statement_type: section.statement_type,
            code: section.code,
            label: section.label,
            normal_balance: section.normal_balance,
            sort_order: section.sort_order,
            parent: section.parent_id && section_map.fetch(section.parent_id)
          )
          section_map[section.id] = copy
        end
        source.financial_statement_assignments.find_each do |assignment|
          draft.financial_statement_assignments.create!(
            tenant_id: source.tenant_id,
            account_id: assignment.account_id,
            financial_statement_section: section_map.fetch(assignment.financial_statement_section_id)
          )
        end
        draft
      end
    end

    def publish!(draft)
      FinancialStatementVersion.transaction do
        Tenant.lock.find(draft.tenant_id)
        draft.lock!
        raise InvalidLayout, "only a draft statement version can be published" unless draft.status == "draft"

        validate_layout!(draft)
        retire_current_version!(draft)
        assert_no_overlap!(draft)
        draft.publishing = true
        draft.update!(status: "active")
        draft
      end
    end

    def validate_layout!(version)
      sections = version.financial_statement_sections.to_a
      codes = sections.map(&:code)
      missing = REQUIRED_CODES - codes
      raise InvalidLayout, "statement layout is missing sections: #{missing.join(", ")}" if missing.any?

      detect_cycles!(sections)
      assigned_ids = version.financial_statement_assignments.pluck(:account_id)
      account_ids = Account.where(tenant_id: version.tenant_id).pluck(:id)
      missing_accounts = account_ids - assigned_ids
      if missing_accounts.any?
        codes = Account.where(id: missing_accounts).order(:code).pluck(:code)
        raise InvalidLayout, "statement layout has unmapped accounts: #{codes.join(", ")}"
      end
    end

    def detect_cycles!(sections)
      by_id = sections.index_by(&:id)
      sections.each do |section|
        seen = {}
        cursor = section
        while cursor
          raise InvalidLayout, "statement section cycle includes #{section.code}" if seen[cursor.id]

          seen[cursor.id] = true
          cursor = cursor.parent_id && by_id[cursor.parent_id]
        end
      end
    end

    def retire_current_version!(draft)
      current = FinancialStatementVersion.for_tenant(draft.tenant_id)
        .where.not(status: "draft")
        .where("effective_from <= ?", draft.effective_from)
        .where("effective_to IS NULL OR effective_to >= ?", draft.effective_from)
        .where.not(id: draft.id)
        .order(effective_from: :desc, version: :desc).first
      return unless current
      if current.effective_from >= draft.effective_from
        raise InvalidLayout, "new version must start after version #{current.version}"
      end

      current.publishing = true
      current.update!(status: "retired", effective_to: draft.effective_from - 1.day)
    end

    def assert_no_overlap!(draft)
      overlap = FinancialStatementVersion.for_tenant(draft.tenant_id)
        .where.not(status: "draft").where.not(id: draft.id)
        .where("effective_from <= ?", draft.effective_to || Date.new(9999, 12, 31))
        .where("effective_to IS NULL OR effective_to >= ?", draft.effective_from)
        .exists?
      raise InvalidLayout, "statement version dates overlap an existing published version" if overlap
    end
  end
end
