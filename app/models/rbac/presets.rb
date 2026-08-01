# frozen_string_literal: true

module Rbac
  # README §6's five roles and their capability matrix, seeded per tenant at onboarding.
  module Presets
    MATRIX = {
      "owner"      => { name: "Owner/Admin", caps: %w[*] },
      "accountant" => { name: "Accountant",
                        caps: %w[documents.post documents.reverse documents.simulate accounts.manage
                                 accounts.read masters.manage masters.read reports.read invoices.create
                                 bills.create payments.create gst.place_of_supply.override contracts.read
                                 contracts.manage contracts.approve] },
      "operator"   => { name: "Operator",
                        caps: %w[invoices.create bills.create payments.create documents.simulate
                                 accounts.read masters.read reports.read gst.place_of_supply.override
                                 contracts.read] },
      "ca_auditor" => { name: "CA/Auditor",
                        caps: %w[documents.post documents.reverse documents.simulate accounts.read
                                 masters.read reports.read period.lock contracts.read] },
      "viewer"     => { name: "Viewer",
                        caps: %w[accounts.read masters.read reports.read contracts.read] }
    }.freeze

    module_function

    # The five v1 presets are centrally managed. Reconciliation adds new capabilities and removes
    # retired ones so a product upgrade cannot silently leave stale authority behind. Tenant-defined
    # custom roles are not a v1 surface and are never touched here.
    def seed_for!(tenant)
      RoleTemplate.transaction do
        tenant.lock!
        MATRIX.each do |code, spec|
          role = RoleTemplate.find_or_initialize_by(tenant_id: tenant.id, code: code)
          role.update!(name: spec.fetch(:name)) if role.new_record? || role.name != spec.fetch(:name)
          desired = spec.fetch(:caps)
          role.role_permissions.where.not(capability: desired).delete_all
          desired.each { |capability| role.role_permissions.find_or_create_by!(capability: capability) }
        end
      end
    end

    def role_for(tenant, code)
      RoleTemplate.find_by(tenant_id: tenant.id, code: code)
    end
  end
end
