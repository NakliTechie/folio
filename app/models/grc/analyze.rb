# frozen_string_literal: true

module Grc
  module Analyze
    SEVERITY_ORDER = { "critical" => 0, "high" => 1, "medium" => 2, "low" => 3 }.freeze

    module_function

    def call(tenant:)
      rules = SodConflictRule.where(tenant_id: tenant.id, active: true).order(:code).to_a
      assignments = UserOfficeRole.where(tenant_id: tenant.id)
        .includes(:user, :posting_limit, :role_template, :office).to_a
      findings = assignments.flat_map do |assignment|
        rules.filter_map { |rule| finding(assignment, rule) }
      end
      findings.sort_by do |item|
        [ SEVERITY_ORDER.fetch(item.fetch("severity")), item.fetch("userEmail"),
          item.fetch("officeCode", ""), item.fetch("ruleCode") ]
      end
    end

    def assignment_snapshot(tenant:)
      UserOfficeRole.where(tenant_id: tenant.id)
        .includes(:user, :posting_limit, :role_template, :office).map do |assignment|
        {
          "assignmentId" => assignment.id,
          "userId" => assignment.user_id,
          "userEmail" => assignment.user.email_address,
          "officeId" => assignment.office_id,
          "officeCode" => assignment.office&.code,
          "roleTemplateId" => assignment.role_template_id,
          "roleCode" => assignment.role_template.code,
          "capabilities" => assignment.role_template.capabilities.sort,
          "postingLimitId" => assignment.posting_limit_id,
          "postingLimitMinor" => assignment.posting_limit&.amount_minor
        }.compact
      end.sort_by { |item| [ item.fetch("userEmail"), item.fetch("officeCode", ""), item.fetch("assignmentId") ] }
    end

    def summary(findings)
      counts = findings.group_by { |finding| finding.fetch("severity") }.transform_values(&:size)
      { "total" => findings.size }.merge(SEVERITY_ORDER.keys.to_h { |severity| [ severity, counts.fetch(severity, 0) ] })
    end

    def finding(assignment, rule)
      caps = assignment.role_template.capabilities
      return unless grants?(caps, rule.capability_a) && grants?(caps, rule.capability_b)

      {
        "ruleId" => rule.id, "ruleCode" => rule.code, "name" => rule.name,
        "severity" => rule.severity, "capabilityA" => rule.capability_a,
        "capabilityB" => rule.capability_b, "description" => rule.description,
        "remediation" => rule.remediation, "assignmentId" => assignment.id,
        "userId" => assignment.user_id, "userEmail" => assignment.user.email_address,
        "roleCode" => assignment.role_template.code,
        "officeId" => assignment.office_id, "officeCode" => assignment.office&.code
      }.compact
    end

    def grants?(capabilities, capability)
      capabilities.include?("*") || capabilities.include?(capability)
    end
  end
end
