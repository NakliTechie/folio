# frozen_string_literal: true

require "test_helper"

class AccountLifecycleTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "account-lifecycle@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Account Lifecycle"
    )
  end

  test "managed creates and changes are mapped and appended to the audit chain" do
    account = assert_difference -> { LedgerEvent.for_tenant(@org.tenant.id).count }, 1 do
      Accounts::Manage.create!(
        tenant: @org.tenant,
        attributes: { code: "AR-20", name: "Other receivables", account_type: "asset" },
        actor: @org.user
      )
    end
    assert_equal "current_assets", account.financial_statement_assignments.first.financial_statement_section.code
    assert_equal "account.created", LedgerEvent.for_tenant(@org.tenant.id).order(:seq).last.action

    assert_difference -> { LedgerEvent.for_tenant(@org.tenant.id).count }, 1 do
      Accounts::Manage.update!(account: account, attributes: { name: "Employee advances" }, actor: @org.user)
    end
    event = LedgerEvent.for_tenant(@org.tenant.id).order(:seq).last
    assert_equal "account.updated", event.action
    assert_equal({ "from" => "Other receivables", "to" => "Employee advances" },
      JSON.parse(event.payload).dig("changes", "name"))
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]
  end

  test "referenced codes and posted accounting types are immutable" do
    account = Account.find_by!(tenant_id: @org.tenant.id, code: "1000")
    document = Document.create!(
      tenant_id: @org.tenant.id,
      entity_id: Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY").id,
      office_id: Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY").id,
      doc_type: "JV",
      document_type: DocumentType.find_by!(tenant_id: @org.tenant.id, code: "JV"),
      fiscal_year: 2026,
      document_date: Date.new(2026, 4, 1),
      posting_date: Date.new(2026, 4, 1),
      state: "draft"
    )
    document.document_lines.create!(tenant_id: @org.tenant.id, line_no: 1,
      account_code: account.code, amount_minor: 100)

    refute account.update(code: "1001")
    assert_includes account.errors[:code], "cannot change after the account is referenced"

    post_journal(debit: "1000", credit: "3000")
    account.reload
    refute account.update(account_type: "expense")
    assert_includes account.errors[:account_type], "cannot change after the account has postings"
  end

  test "deactivated accounts remain historical but cannot receive new postings" do
    account = Account.find_by!(tenant_id: @org.tenant.id, code: "1000")
    post_journal(debit: "1000", credit: "3000")
    Accounts::Manage.update!(account: account, attributes: { active: false }, actor: @org.user)

    assert_equal "account.deactivated", LedgerEvent.for_tenant(@org.tenant.id).order(:seq).last.action
    refute Account.active.exists?(account.id)
    error = assert_raises(Documents::Post::InactiveAccount) do
      post_journal(debit: "1000", credit: "3000")
    end
    assert_match "1000", error.message
    assert Account.exists?(account.id), "deactivation never deletes the historical master"
  end

  test "an account with an open draft cannot be deactivated and strand that draft" do
    account = Account.find_by!(tenant_id: @org.tenant.id, code: "1000")
    entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    type = DocumentType.find_by!(tenant_id: @org.tenant.id, code: "JV")
    draft = Document.create!(tenant_id: @org.tenant.id, entity_id: entity.id, office_id: office.id,
      doc_type: "JV", document_type: type, fiscal_year: 2026,
      document_date: Date.new(2026, 4, 1), posting_date: Date.new(2026, 4, 1), state: "draft")
    draft.document_lines.create!(tenant_id: @org.tenant.id, line_no: 1,
      account_code: "1000", amount_minor: 100)
    draft.document_lines.create!(tenant_id: @org.tenant.id, line_no: 2,
      account_code: "3000", amount_minor: -100)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      Accounts::Manage.update!(account: account, attributes: { active: false }, actor: @org.user)
    end
    assert_match(/open draft/, error.message)
    assert account.reload.active?
    assert_equal "draft", draft.reload.state
  end

  private

  def post_journal(debit:, credit:)
    entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    type = DocumentType.find_by!(tenant_id: @org.tenant.id, code: "JV")
    doc = Document.create!(tenant_id: @org.tenant.id, entity_id: entity.id, office_id: office.id,
      doc_type: "JV", document_type: type, fiscal_year: 2026,
      document_date: Date.new(2026, 4, 1), posting_date: Date.new(2026, 4, 1), state: "draft")
    doc.document_lines.create!(tenant_id: @org.tenant.id, line_no: 1,
      account_code: debit, amount_minor: 10_000)
    doc.document_lines.create!(tenant_id: @org.tenant.id, line_no: 2,
      account_code: credit, amount_minor: -10_000)
    Documents::Post.call(doc, actor: "u:#{@org.user.id}")
  end
end
