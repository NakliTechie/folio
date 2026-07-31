# frozen_string_literal: true

module Onboarding
  # Self-serve signup: create the User, the Tenant, the owner Membership + owner role, seed the
  # RBAC roles and starter books — all in ONE transaction, so a half-created org can never exist.
  module SignUp
    Result = Struct.new(:user, :tenant, keyword_init: true)

    module_function

    def call(email:, password:, org_name:, jurisdiction_profile: nil, functional_currency: nil,
             fiscal_year_variant: nil, time_zone: nil)
      profile = AccountingProfile.resolve(
        jurisdiction_profile: jurisdiction_profile,
        functional_currency: functional_currency,
        fiscal_year_variant: fiscal_year_variant,
        time_zone: time_zone
      )

      ActiveRecord::Base.transaction do
        user = User.create!(email_address: email, password: password)
        tenant = create_tenant!(
          name: org_name.presence || "My Company",
          functional_currency: profile.functional_currency,
          time_zone: profile.time_zone
        )
        Membership.create!(user: user, tenant: tenant)
        Rbac::Presets.seed_for!(tenant)
        UserOfficeRole.create!(user: user, tenant_id: tenant.id,
          role_template: Rbac::Presets.role_for(tenant, "owner"))
        Seeds.org_spine!(
          tenant,
          jurisdiction_profile: profile.jurisdiction_profile,
          fiscal_year_variant: profile.fiscal_year_variant
        )
        Seeds.chart_of_accounts!(tenant, jurisdiction_profile: profile.jurisdiction_profile)
        Seeds.document_types!(tenant)
        Seeds.financial_statements!(tenant)
        Result.new(user: user, tenant: tenant)
      end
    end

    # The unique database index is the final authority. A savepoint keeps a slug collision
    # from poisoning the outer all-or-nothing signup transaction.
    def create_tenant!(name:, functional_currency:, time_zone:)
      loop do
        tenant = nil
        Tenant.transaction(requires_new: true) do
          tenant = Tenant.create!(
            name: name,
            slug: Onboarding.slugify(name),
            functional_currency: functional_currency,
            time_zone: time_zone
          )
        end
        return tenant
      rescue ActiveRecord::RecordNotUnique
        next
      end
    end
  end
end
