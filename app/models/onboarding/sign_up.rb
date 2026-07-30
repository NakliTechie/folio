# frozen_string_literal: true

module Onboarding
  # Self-serve signup: create the User, the Tenant, the owner Membership + owner role, seed the
  # RBAC roles and starter books — all in ONE transaction, so a half-created org can never exist.
  module SignUp
    Result = Struct.new(:user, :tenant, keyword_init: true)

    module_function

    def call(email:, password:, org_name:)
      ActiveRecord::Base.transaction do
        user = User.create!(email_address: email, password: password)
        tenant = Tenant.create!(name: org_name.presence || "My Company", slug: Onboarding.slugify(org_name))
        Membership.create!(user: user, tenant: tenant)
        Rbac::Presets.seed_for!(tenant)
        UserOfficeRole.create!(user: user, tenant_id: tenant.id,
          role_template: Rbac::Presets.role_for(tenant, "owner"))
        Seeds.org_spine!(tenant)
        Seeds.chart_of_accounts!(tenant)
        Seeds.document_types!(tenant)
        Result.new(user: user, tenant: tenant)
      end
    end
  end
end
