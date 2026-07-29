# frozen_string_literal: true

# Server-side capability + posting-limit checks (README §6: "capability checks server-side on
# every mutation"). Resolves a user's role via user_office_roles, most-specific office first.
module Authorization
  module_function

  # tenant_id (not a tenant object) is taken so callers bind it to the RESOURCE (e.g. the
  # document's tenant), never to a caller-supplied value. Resolution is strict: the specific
  # office role, else the tenant-wide (office_id nil) role, else NIL — no arbitrary fall-through,
  # so a miss denies rather than escalating to some other role the user happens to hold.
  def role_for(user:, tenant_id:, office_id: nil)
    scope = UserOfficeRole.where(user_id: user.id, tenant_id: tenant_id)
    (office_id && scope.find_by(office_id: office_id)) || scope.find_by(office_id: nil)
  end

  def permits?(user:, tenant_id:, capability:, office_id: nil, amount_minor: nil)
    uor = role_for(user: user, tenant_id: tenant_id, office_id: office_id)
    return false unless uor && uor.role_template.permits?(capability)
    if amount_minor && uor.posting_limit
      return false if amount_minor.abs > uor.posting_limit.amount_minor
    end
    true
  end

  # The authority to STAMP on a posted entry (spec §11): which role + limit it was posted under.
  def authority_for(user:, tenant_id:, office_id: nil)
    uor = role_for(user: user, tenant_id: tenant_id, office_id: office_id)
    { role_template_id: uor&.role_template_id, posting_limit_id: uor&.posting_limit_id }
  end
end
