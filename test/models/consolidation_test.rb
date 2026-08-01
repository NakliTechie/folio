# frozen_string_literal: true

require "test_helper"

class ConsolidationTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "consolidation@folio.invalid", password: "correct-horse-battery",
      org_name: "Consolidation Group"
    )
    @group = ConsolidationGroup.find_by!(tenant_id: @org.tenant.id, code: "GROUP")
    @seller = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @buyer = Consolidation::Manage.create_entity!(
      tenant: @org.tenant, group: @group, actor: @org.user,
      attributes: {
        code: "SUB", legal_name: "Subsidiary Limited", office_name: "Subsidiary Office",
        effective_from: "2026-04-01"
      }
    )
  end

  test "matched intercompany posting balances both legal entities and is exactly idempotent" do
    transaction = post_intercompany
    duplicate = post_intercompany
    assert_equal transaction.id, duplicate.id
    entry = Entry.find_by!(ledger_event_id: transaction.ledger_event_id)
    assert_equal [ @seller.id, @buyer.id ], entry.entry_lines.distinct.order(:entity_id).pluck(:entity_id)
    entry.entry_lines.group_by(&:entity_id).each_value do |lines|
      assert_equal 0, lines.sum { |line| line.amounts.sole.amount_minor }
    end
    assert_equal [ @buyer.id, @buyer.id, @seller.id, @seller.id ],
      entry.entry_lines.order(:line_no).pluck(:partner_entity_id)
    assert_equal 1, entry.entry_lines.distinct.pluck(:intercompany_transaction_id).size
    assert EventSigning.verify(LedgerEvent.find(transaction.ledger_event_id))
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]

    changed = intercompany_attributes.merge(amount: "101")
    assert_match(/already belongs/, assert_raises(Consolidation::InvalidConsolidation) {
      Consolidation::PostIntercompany.call(group: @group, actor: @org.user, attributes: changed)
    }.message)
  end

  test "elimination negates internal balances without changing either entity's legal books" do
    transaction = post_intercompany
    before = Consolidation::Report.trial_balance(group: @group, as_of: "2026-08-31")
    assert_equal [ -10_000, -10_000, 10_000, 10_000 ],
      before.fetch(:rows).pluck(:base_minor).sort
    assert before.fetch(:rows).all? { |row| row.fetch(:eliminations_minor).zero? }

    run = Consolidation::Eliminate.call(
      transaction: transaction, actor: @org.user,
      attributes: { posting_date: "2026-08-31", idempotency_key: "eliminate-1" }
    )
    duplicate = Consolidation::Eliminate.call(
      transaction: transaction, actor: @org.user,
      attributes: { posting_date: "2026-08-31", idempotency_key: "eliminate-1" }
    )
    assert_equal run.id, duplicate.id
    report = Consolidation::Report.trial_balance(group: @group, as_of: "2026-08-31")
    assert report.fetch(:rows).all? { |row| row.fetch(:consolidated_minor).zero? }
    assert_equal [ -10_000, -10_000, 10_000, 10_000 ],
      report.fetch(:rows).pluck(:eliminations_minor).sort

    legal = EntryLine.where(
      tenant_id: @org.tenant.id, posting_layer: "00",
      intercompany_transaction_id: transaction.transaction_code
    )
    assert_equal 4, legal.count
    assert_equal 4, EntryLine.where(
      tenant_id: @org.tenant.id, posting_layer: "EL",
      intercompany_transaction_id: transaction.transaction_code
    ).count
    assert_raises(ActiveRecord::StatementInvalid) do
      ConsolidationEliminationRun.transaction(requires_new: true) do
        run.update_column(:posting_date, Date.new(2026, 9, 1))
      end
    end
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]
    Posting.rebuild!(@org.tenant.id)
    assert_equal 4, EntryLine.where(
      tenant_id: @org.tenant.id, posting_layer: "EL",
      intercompany_transaction_id: transaction.transaction_code
    ).count
  end

  test "group policy fails closed for cross-currency entities and viewer posting" do
    foreign = Entity.create!(
      tenant_id: @org.tenant.id, code: "USD", legal_name: "Dollar Subsidiary",
      functional_currency: "USD", fiscal_year_variant: @seller.fiscal_year_variant,
      jurisdiction_profile: @seller.jurisdiction_profile
    )
    error = assert_raises(Consolidation::InvalidConsolidation) do
      Consolidation::Manage.add_member!(
        group: @group, entity: foreign, effective_from: Date.new(2026, 4, 1)
      )
    end
    assert_match(/translation policy/, error.message)

    viewer = invite_user("consolidation-viewer@folio.invalid", "viewer")
    assert_raises(Consolidation::InvalidConsolidation) do
      Consolidation::PostIntercompany.call(
        group: @group, actor: viewer, attributes: intercompany_attributes
      )
    end
    assert Authorization.permits?(
      user: viewer, tenant_id: @org.tenant.id, capability: "consolidation.read"
    )
  end

  private

  def post_intercompany
    Consolidation::PostIntercompany.call(
      group: @group, actor: @org.user, attributes: intercompany_attributes
    )
  end

  def intercompany_attributes
    {
      seller_entity_id: @seller.id, buyer_entity_id: @buyer.id,
      posting_date: "2026-08-15", amount: "100", description: "Shared services",
      seller_receivable_account_code: "1200", seller_revenue_account_code: "4000",
      buyer_expense_account_code: "5100", buyer_payable_account_code: "2000",
      idempotency_key: "intercompany-1"
    }
  end

  def invite_user(email, role_code)
    invitation = Onboarding::Invite.create!(
      tenant: @org.tenant, email: email, role_code: role_code, invited_by: @org.user
    )
    Onboarding::Invite.accept!(
      token: invitation.generate_token_for(:invite), password: "correct-horse-battery"
    )
  end
end
