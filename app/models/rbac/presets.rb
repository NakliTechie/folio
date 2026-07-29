# frozen_string_literal: true

module Rbac
  # README §6's five roles and their capability matrix, seeded per tenant at onboarding.
  module Presets
    MATRIX = {
      "owner"      => { name: "Owner/Admin", caps: %w[*] },
      "accountant" => { name: "Accountant",
                        caps: %w[documents.post documents.reverse documents.simulate accounts.manage
                                 masters.manage reports.read invoices.create payments.create] },
      "operator"   => { name: "Operator",
                        caps: %w[invoices.create payments.create documents.simulate reports.read] },
      "ca_auditor" => { name: "CA/Auditor",
                        caps: %w[documents.post documents.reverse documents.simulate reports.read period.lock] },
      "viewer"     => { name: "Viewer", caps: %w[reports.read] }
    }.freeze

    module_function

    # Idempotent: seed (or top up) the five roles + their permissions for a tenant.
    def seed_for!(tenant)
      MATRIX.each do |code, spec|
        rt = RoleTemplate.find_or_create_by!(tenant_id: tenant.id, code: code) { |r| r.name = spec[:name] }
        spec[:caps].each { |c| RolePermission.find_or_create_by!(role_template: rt, capability: c) }
      end
    end

    def role_for(tenant, code)
      RoleTemplate.find_by(tenant_id: tenant.id, code: code)
    end
  end
end
