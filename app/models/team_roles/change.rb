# frozen_string_literal: true

module TeamRoles
  # Invitations add people; this service is the only product path for changing an existing
  # member's tenant-wide authority. The tenant lock serializes competing owner demotions and
  # the database trigger independently protects console/import writers.
  module Change
    module_function

    def call!(tenant:, user:, role_code:, actor:)
      UserOfficeRole.transaction do
        tenant.lock!
        Membership.find_by!(tenant: tenant, user: user)
        Rbac::Presets.seed_for!(tenant)
        next_role = Rbac::Presets.role_for(tenant, role_code)
        raise InvalidRole, "Choose a supported role." unless next_role

        assignment = UserOfficeRole.lock.find_or_initialize_by(
          tenant_id: tenant.id, user_id: user.id, office_id: nil
        )
        previous_role = assignment.role_template
        return assignment if previous_role == next_role

        if previous_role&.code == "owner" && next_role.code != "owner" &&
            tenant_wide_owner_count(tenant) <= 1
          raise LastOwner, "Add another owner before changing the final owner's role."
        end

        assignment.update!(role_template: next_role)
        MasterData::Audit.append!(
          tenant_id: tenant.id,
          actor: actor,
          action: "team.role_changed",
          ref: user.email_address,
          subject: {
            "userId" => user.id,
            "email" => user.email_address,
            "role" => next_role.code
          },
          changes: {
            "role" => { "from" => previous_role&.code, "to" => next_role.code }
          }
        )
        assignment
      end
    end

    def tenant_wide_owner_count(tenant)
      UserOfficeRole.joins(:role_template).where(
        tenant_id: tenant.id,
        office_id: nil,
        role_templates: { tenant_id: tenant.id, code: "owner" }
      ).count
    end
    private_class_method :tenant_wide_owner_count
  end
end
