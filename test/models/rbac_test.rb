# frozen_string_literal: true

require "test_helper"

# M2.3 — RBAC is a matrix (D13/§11, README §6): roles carry capabilities, users get roles
# per office, and the posting entry point enforces capability + posting limit and stamps the
# authority on the entry. Authority is always resolved against the RESOURCE's tenant, strictly
# (no arbitrary role fall-through) — a role held elsewhere can never authorize a post here.
class RbacTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: "Acme", slug: "acme-rbac")
    Rbac::Presets.seed_for!(@tenant)
    Onboarding::Seeds.org_spine!(@tenant)
    @jv = DocumentType.create!(tenant_id: @tenant.id, code: "JV", label: "JV",
      posting_rule: "journal_voucher", number_prefix: "JV/")
    Account.create!(tenant_id: @tenant.id, code: "1000", name: "Cash", account_type: "asset")
    Account.create!(tenant_id: @tenant.id, code: "4000", name: "Sales", account_type: "income")

    @owner = user_with("owner@x.com", "owner")
    @operator = user_with("op@x.com", "operator")
  end

  def user_with(email, role_code, tenant: @tenant, office_id: nil)
    u = User.find_or_create_by!(email_address: email) { |x| x.password = "password" }
    Membership.find_or_create_by!(user: u, tenant: tenant)
    UserOfficeRole.create!(user: u, tenant_id: tenant.id, office_id: office_id,
      role_template: Rbac::Presets.role_for(tenant, role_code))
    u
  end

  def build_jv(amount: 100_000, tenant: @tenant)
    entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
    office = Office.find_by!(tenant_id: tenant.id, code: "PRIMARY")
    document_type = DocumentType.find_by!(tenant_id: tenant.id, code: "JV")
    doc = Document.create!(tenant_id: tenant.id, entity_id: entity.id, office_id: office.id, doc_type: "JV",
      document_type_id: document_type.id, fiscal_year: 2025, document_date: Date.new(2025, 6, 1),
      posting_date: Date.new(2025, 6, 1), state: "draft")
    doc.document_lines.create!(tenant_id: tenant.id, line_no: 1, account_code: "1000", amount_minor: amount)
    doc.document_lines.create!(tenant_id: tenant.id, line_no: 2, account_code: "4000", amount_minor: -amount)
    doc
  end

  test "the five preset roles carry README §6 capabilities" do
    assert_equal %w[accountant ca_auditor operator owner viewer],
      RoleTemplate.where(tenant_id: @tenant.id).pluck(:code).sort
    assert Rbac::Presets.role_for(@tenant, "owner").permits?("anything.at.all"), "owner is the * wildcard"
    assert Rbac::Presets.role_for(@tenant, "accountant").permits?("documents.post")
    refute Rbac::Presets.role_for(@tenant, "operator").permits?("documents.post"), "operator cannot post vouchers"
    refute Rbac::Presets.role_for(@tenant, "operator").permits?("accounts.manage"), "operator cannot edit the COA"
    assert Rbac::Presets.role_for(@tenant, "viewer").permits?("reports.read")
    refute Rbac::Presets.role_for(@tenant, "viewer").permits?("documents.post"), "viewer is read-only"
  end

  test "Authorization.permits? resolves the user's role in the given tenant" do
    assert Authorization.permits?(user: @owner, tenant_id: @tenant.id, capability: "documents.post")
    refute Authorization.permits?(user: @operator, tenant_id: @tenant.id, capability: "documents.post")
    stranger = User.create!(email_address: "stranger@x.com", password: "password")
    refute Authorization.permits?(user: stranger, tenant_id: @tenant.id, capability: "reports.read")
  end

  test "a role held in another tenant does not authorize here" do
    other = Tenant.create!(name: "Globex", slug: "globex-rbac")
    Rbac::Presets.seed_for!(other)
    # @owner is owner in @tenant, but has NO role in `other`.
    refute Authorization.permits?(user: @owner, tenant_id: other.id, capability: "documents.post"),
      "an owner of Acme is not an owner of Globex"
  end

  test "role resolution is strict — an office miss denies, it does not fall through to another role" do
    # office-1 operator only; NO tenant-wide role.
    u = user_with("scoped@x.com", "operator", office_id: 1)
    assert Authorization.permits?(user: u, tenant_id: @tenant.id, capability: "invoices.create", office_id: 1)
    # a different office → no match, no tenant-wide role → DENY (not an escalation to some other role)
    refute Authorization.permits?(user: u, tenant_id: @tenant.id, capability: "invoices.create", office_id: 999)
  end

  test "a posting limit caps what an authority may post, regardless of capability" do
    limit = PostingLimit.create!(tenant_id: @tenant.id, name: "50k", amount_minor: 5_000_000)
    @owner.user_office_roles.first.update!(posting_limit: limit)
    assert Authorization.permits?(user: @owner, tenant_id: @tenant.id, capability: "documents.post", amount_minor: 4_000_000)
    refute Authorization.permits?(user: @owner, tenant_id: @tenant.id, capability: "documents.post", amount_minor: 6_000_000)
  end

  test "Documents::Post enforces RBAC and stamps the authority on the entry (§11)" do
    doc = build_jv
    assert_raises(Documents::Post::NotPermitted) do
      Documents::Post.call(doc, actor: "op", authorize: { user: @operator })
    end
    assert_equal "draft", doc.reload.state, "a denied post writes nothing"

    entry = Documents::Post.call(build_jv, actor: "owner", authorize: { user: @owner })
    assert_equal Rbac::Presets.role_for(@tenant, "owner").id, entry.role_template_id,
      "the posted entry records the authority it was posted under"
  end

  test "a role's capabilities reach restricted-period enforcement" do
    auditor = user_with("auditor@x.com", "ca_auditor")
    entity = Entity.find_by!(tenant_id: @tenant.id, code: "PRIMARY")
    ledger = Ledger.find_by!(tenant_id: @tenant.id, code: "PRIMARY")
    PeriodControl.create!(tenant_id: @tenant.id, entity_id: entity.id, ledger_id: ledger.id,
      account_class: "ALL", fiscal_year: 2025, period_no: 3, state: "restricted",
      capability: "period.lock", domain: "posting")

    assert Documents::Post.call(build_jv, actor: "auditor", authorize: { user: auditor }).persisted?
    assert Documents::Post.call(build_jv, actor: "owner", authorize: { user: @owner }).persisted?,
      "the owner wildcard satisfies a named restricted-period capability"
  end

  test "the authority is bound to the DOCUMENT's tenant, not the caller's context" do
    # @owner is owner of @tenant. A document in ANOTHER tenant must not be postable by @owner
    # even if the caller passes @owner as the authorizer.
    other = Tenant.create!(name: "Other", slug: "other-rbac")
    Rbac::Presets.seed_for!(other)
    Onboarding::Seeds.org_spine!(other)
    DocumentType.create!(tenant_id: other.id, code: "JV", label: "JV", posting_rule: "journal_voucher")
    Account.create!(tenant_id: other.id, code: "1000", name: "Cash", account_type: "asset")
    Account.create!(tenant_id: other.id, code: "4000", name: "Sales", account_type: "income")
    foreign_doc = build_jv(tenant: other)

    assert_raises(Documents::Post::NotPermitted) do
      Documents::Post.call(foreign_doc, actor: "owner", authorize: { user: @owner })
    end
    assert_equal 0, Entry.where(tenant_id: other.id).count, "no cross-tenant authority leak"
  end

  test "a post over the actor's posting limit is rejected, writing nothing" do
    @owner.user_office_roles.first.update!(
      posting_limit: PostingLimit.create!(tenant_id: @tenant.id, name: "1k", amount_minor: 100_000)
    )
    doc = build_jv(amount: 200_000)
    assert_raises(Documents::Post::NotPermitted) do
      Documents::Post.call(doc, actor: "owner", authorize: { user: @owner })
    end
    assert_equal 0, Entry.where(tenant_id: @tenant.id).count
  end

  test "an internal post with no authorize context is unaffected (engine tests still work)" do
    entry = Documents::Post.call(build_jv, actor: "system")
    assert entry.persisted?
    assert_nil entry.role_template_id, "no authority stamped when none is asserted"
  end
end
