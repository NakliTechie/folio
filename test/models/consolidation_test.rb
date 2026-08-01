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
    seller_book = Reports.trial_balance(
      @org.tenant.id, entity_id: @seller.id
    ).index_by { |row| row.fetch("account_id") }
    buyer_book = Reports.trial_balance(
      @org.tenant.id, entity_id: @buyer.id
    ).index_by { |row| row.fetch("account_id") }
    assert_equal 10_000, seller_book.fetch(1200).fetch("debit")
    assert_equal 10_000, seller_book.fetch(4000).fetch("credit")
    assert_equal 10_000, buyer_book.fetch(5100).fetch("debit")
    assert_equal 10_000, buyer_book.fetch(2000).fetch("credit")
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

  test "group report includes only postings made while each entity was a member" do
    post_entity_journal(@buyer, Date.new(2026, 3, 31), 7_000)
    post_entity_journal(@buyer, Date.new(2026, 4, 1), 11_000)

    report = Consolidation::Report.trial_balance(group: @group, as_of: "2026-08-31")
    rows = report.fetch(:rows).index_by { |row| row.fetch(:account_code) }

    assert_equal 11_000, rows.fetch("1000").fetch(:base_minor)
    assert_equal(-11_000, rows.fetch("4000").fetch(:base_minor))
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

  test "an elimination cannot precede its source transaction" do
    transaction = post_intercompany

    error = assert_raises(Consolidation::InvalidConsolidation) do
      Consolidation::Eliminate.call(
        transaction: transaction, actor: @org.user,
        attributes: { posting_date: "2026-08-14", idempotency_key: "early-elimination" }
      )
    end

    assert_match(/cannot precede/, error.message)
    assert_nil ConsolidationEliminationRun.find_by(
      tenant_id: @org.tenant.id, idempotency_key: "early-elimination"
    )
  end

  private

  def post_intercompany
    Consolidation::PostIntercompany.call(
      group: @group, actor: @org.user, attributes: intercompany_attributes
    )
  end

  def post_entity_journal(entity, date, amount_minor)
    office = Office.where(tenant_id: @org.tenant.id, entity_id: entity.id).first!
    ledger = Ledger.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    Posting::PostEntry.post!(
      tenant_id: @org.tenant.id, actor: "u:#{@org.user.id}", actor_user_id: @org.user.id,
      document_date: date, posting_date: date, entered_at: date.to_time,
      fiscal_year: Documents.fiscal_year(date, variant: entity.fiscal_year_variant),
      period_no: Documents.period_no(date, variant: entity.fiscal_year_variant),
      lines: [
        entity_line(1, entity, office, ledger, "1000", amount_minor),
        entity_line(2, entity, office, ledger, "4000", -amount_minor)
      ]
    )
  end

  def entity_line(number, entity, office, ledger, account_code, amount_minor)
    {
      line_no: number, account_code: account_code, ledger_id: ledger.id,
      entity_id: entity.id, office_id: office.id,
      amounts: [ {
        slot_role: "transaction", currency: entity.functional_currency,
        minor_unit_exponent: 2, amount_minor: amount_minor
      } ]
    }
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
