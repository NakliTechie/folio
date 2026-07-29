# frozen_string_literal: true

require "test_helper"

# M2.3 — RBAC is a matrix (D13/§11, README §6): roles carry capabilities, users get roles
# per office, and the posting entry point enforces capability + posting limit and stamps the
# authority on the entry.
class RbacTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: "Acme", slug: "acme-rbac")
    Rbac::Presets.seed_for!(@tenant)
    @jv = DocumentType.create!(tenant_id: @tenant.id, code: "JV", label: "JV",
      posting_rule: "journal_voucher", number_prefix: "JV/")
    Account.create!(tenant_id: @tenant.id, code: "1000", name: "Cash", account_type: "asset")
    Account.create!(tenant_id: @tenant.id, code: "4000", name: "Sales", account_type: "income")

    @owner = user_with("owner@x.com", "owner")
    @operator = user_with("op@x.com", "operator")
  end

  def user_with(email, role_code)
    u = User.create!(email_address: email, password: "password")
    Membership.create!(user: u, tenant: @tenant)
    UserOfficeRole.create!(user: u, tenant_id: @tenant.id, role_template: Rbac::Presets.role_for(@tenant, role_code))
    u
  end

  def build_jv(amount: 100_000)
    doc = Document.create!(tenant_id: @tenant.id, entity_id: 1, office_id: 1, doc_type: "JV",
      document_type_id: @jv.id, fiscal_year: 2025, document_date: Date.new(2025, 6, 1),
      posting_date: Date.new(2025, 6, 1), state: "draft")
    doc.document_lines.create!(tenant_id: @tenant.id, line_no: 1, account_code: "1000", amount_minor: amount)
    doc.document_lines.create!(tenant_id: @tenant.id, line_no: 2, account_code: "4000", amount_minor: -amount)
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

  test "Authorization.permits? resolves the user's role" do
    assert Authorization.permits?(user: @owner, tenant: @tenant, capability: "documents.post")
    refute Authorization.permits?(user: @operator, tenant: @tenant, capability: "documents.post")
    # a user with no role in the tenant is denied everything
    stranger = User.create!(email_address: "stranger@x.com", password: "password")
    refute Authorization.permits?(user: stranger, tenant: @tenant, capability: "reports.read")
  end

  test "a posting limit caps what an authority may post, regardless of capability" do
    limit = PostingLimit.create!(tenant_id: @tenant.id, name: "50k", amount_minor: 5_000_000)
    @owner.user_office_roles.first.update!(posting_limit: limit)
    assert Authorization.permits?(user: @owner, tenant: @tenant, capability: "documents.post", amount_minor: 4_000_000)
    refute Authorization.permits?(user: @owner, tenant: @tenant, capability: "documents.post", amount_minor: 6_000_000)
  end

  test "Documents::Post enforces RBAC and stamps the authority on the entry (§11)" do
    doc = build_jv
    assert_raises(Documents::Post::NotPermitted) do
      Documents::Post.call(doc, actor: "op", authorize: { user: @operator, tenant: @tenant })
    end
    assert_equal "draft", doc.reload.state, "a denied post writes nothing"

    entry = Documents::Post.call(build_jv, actor: "owner", authorize: { user: @owner, tenant: @tenant })
    assert_equal Rbac::Presets.role_for(@tenant, "owner").id, entry.role_template_id,
      "the posted entry records the authority it was posted under"
  end

  test "a post over the actor's posting limit is rejected, writing nothing" do
    @owner.user_office_roles.first.update!(
      posting_limit: PostingLimit.create!(tenant_id: @tenant.id, name: "1k", amount_minor: 100_000)
    )
    doc = build_jv(amount: 200_000)
    assert_raises(Documents::Post::NotPermitted) do
      Documents::Post.call(doc, actor: "owner", authorize: { user: @owner, tenant: @tenant })
    end
    assert_equal 0, Entry.where(tenant_id: @tenant.id).count
  end

  test "an internal post with no authorize context is unaffected (engine tests still work)" do
    entry = Documents::Post.call(build_jv, actor: "system")
    assert entry.persisted?
    assert_nil entry.role_template_id, "no authority stamped when none is asserted"
  end
end
