# frozen_string_literal: true

if Rails.env.production? && ENV["FOLIO_ALLOW_PRODUCTION_DEMO_SEED"] != "I_ACCEPT_DEMO_DATA_RISK"
  abort "Refusing to seed demo accounts in production. Use a non-production environment."
end

password = ENV.fetch("FOLIO_DEMO_PASSWORD")
tenant = Tenant.find_or_create_by!(slug: "folio-demo") do |record|
  record.name = "Folio Demo"
end

Rbac::Presets.seed_for!(tenant)
Onboarding::Seeds.org_spine!(tenant)
Onboarding::Seeds.chart_of_accounts!(tenant)
Onboarding::Seeds.document_types!(tenant)
Onboarding::Seeds.financial_statements!(tenant)

Rbac::Presets::MATRIX.each_key do |role_code|
  email = "demo-#{role_code.tr("_", "-")}@folio.invalid"
  user = User.find_or_initialize_by(email_address: email)
  user.password = password
  user.password_confirmation = password
  user.save!
  user.verify! unless user.verified?

  Membership.find_or_create_by!(user: user, tenant: tenant)
  assignment = UserOfficeRole.find_or_initialize_by(user: user, tenant_id: tenant.id, office_id: nil)
  assignment.role_template = Rbac::Presets.role_for(tenant, role_code)
  assignment.save!
end

puts "Seeded Folio Demo with #{Rbac::Presets::MATRIX.size} role accounts."
