# frozen_string_literal: true

require "test_helper"

class ControllingTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "controlling@folio.invalid", password: "correct-horse-battery",
      org_name: "Controlling Books"
    )
    @segment = Controlling::Manage.create_segment!(
      tenant: @org.tenant, actor: @org.user, attributes: { code: "MFG", name: "Manufacturing" }
    )
    @profit = Controlling::Manage.create_profit_center!(
      tenant: @org.tenant, actor: @org.user,
      attributes: {
        code: "OPS", name: "Operations", controlling_segment_id: @segment.id,
        valid_from: "2026-04-01"
      }
    )
    @sender = create_center("ADMIN", "Administration")
    @receiver_one = create_center("PAINT", "Paint shop")
    @receiver_two = create_center("MACHINE", "Machine shop")
    @cycle = Controlling::Manage.create_cycle!(
      tenant: @org.tenant, actor: @org.user,
      attributes: {
        code: "ADMIN-OH", name: "Distribute admin overhead",
        sender_cost_center_id: @sender.id, source_account_code: "5100",
        valid_from: "2026-04-01"
      },
      receivers: [
        { cost_center_id: @receiver_one.id, weight_basis_points: 3333 },
        { cost_center_id: @receiver_two.id, weight_basis_points: 6667 }
      ]
    )
  end

  test "governed journal dimensions survive replay and reject cross-tenant snapshots" do
    document = post_expense(10_001)
    posted_entry = Entry.find(document.posted_entry_id)
    debit = posted_entry.entry_lines.find_by!(account_code: "5100")
    assert_equal [ "cost_center", @sender.id, @profit.id, @segment.id ],
      debit.values_at(:cost_object_type, :cost_object_id, :profit_center_id, :segment_id)

    Posting.rebuild!(@org.tenant.id)
    rebuilt = Entry.find_by!(ledger_event_id: posted_entry.ledger_event_id)
      .entry_lines.find_by!(account_code: "5100")
    assert_equal [ @sender.id, @profit.id, @segment.id ],
      rebuilt.values_at(:cost_object_id, :profit_center_id, :segment_id)

    other = Onboarding::SignUp.call(
      email: "other-control@folio.invalid", password: "correct-horse-battery", org_name: "Other Control"
    )
    foreign = CostCenter.find_by!(tenant_id: other.tenant.id, code: "GENERAL")
    assert_raises(Documents::InvalidDocument) do
      Documents::BuildDraft.call(
        tenant: @org.tenant, doc_type: "JV", document_date: "2026-08-10",
        posting_date: "2026-08-10", narration: "Cross tenant", lines: [
          { account_code: "5100", amount_minor: 100, currency: "INR",
            extra: { "controlling" => Controlling::Dimensions.snapshot(foreign, on: "2026-08-10") } },
          { account_code: "1000", amount_minor: -100, currency: "INR" }
        ]
      )
    end
  end

  test "distribution allocates the exact sender balance and is delta-safe on repeat" do
    post_expense(10_001)
    simulation = run_cycle("simulate", "preview")
    assert_equal 10_001, simulation.allocated_amount_minor
    assert_nil simulation.ledger_event_id

    posted = run_cycle("post", "allocate")
    assert_equal 10_001, posted.allocated_amount_minor
    assert_equal [ 3333, 6668 ], posted.allocation_run_items.order(:receiver_cost_center_id).pluck(:amount_minor)
    assert posted.ledger_event_id
    lines = Entry.find_by!(ledger_event_id: posted.ledger_event_id).entry_lines.order(:line_no)
    assert_equal [ 3333, 6668, -10_001 ], lines.map { |line| line.amounts.sole.amount_minor }
    assert_equal [ @receiver_one.id, @receiver_two.id, @sender.id ], lines.pluck(:cost_object_id)
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]

    zero = run_cycle("post", "allocate-again")
    assert_equal 0, zero.allocated_amount_minor
    assert_nil zero.ledger_event_id
    assert_empty zero.allocation_run_items
    assert_equal posted.id, run_cycle("post", "allocate").id

    assert_raises(ActiveRecord::StatementInvalid) do
      AllocationRun.transaction(requires_new: true) { posted.update_column(:allocated_amount_minor, 1) }
    end

    error = assert_raises(Controlling::InvalidControl) do
      Controlling::RunAllocation.call(
        cycle: @cycle, actor: @org.user,
        attributes: {
          through_date: "2026-08-31", posting_date: "2026-09-01",
          mode: "post", idempotency_key: "wrong-posting-period"
        }
      )
    end
    assert_match(/must equal/, error.message)
  end

  test "plan lines share the actual account and cost-center coordinates" do
    post_expense(10_001)
    plan = Controlling::Manage.create_plan_line!(
      tenant: @org.tenant, actor: @org.user,
      attributes: {
        cost_center_id: @sender.id, account_code: "5100", version: "budget",
        fiscal_year: 2026, period_no: 5, amount: "100"
      }
    )
    assert_equal [ "BUDGET", "INR", 10_000 ], plan.values_at(:version, :currency, :amount_minor)
    range = PeriodControls::Calendar.date_range(
      entity: @sender.entity, fiscal_year: plan.fiscal_year, period_no: plan.period_no
    )
    actual = JournalEntryLineAmount.joins(entry_line: :entry).where(
      entry_lines: {
        tenant_id: @org.tenant.id, cost_object_type: "cost_center",
        cost_object_id: @sender.id, account_code: "5100"
      }, entries: { posting_date: range }, slot_role: "transaction", currency: "INR"
    ).sum(:amount_minor)
    assert_equal 10_001, actual
  end

  test "cycles require an exact 100 percent receiver basis" do
    error = assert_raises(Controlling::InvalidControl) do
      Controlling::Manage.create_cycle!(
        tenant: @org.tenant, actor: @org.user,
        attributes: {
          code: "BAD", name: "Bad", sender_cost_center_id: @sender.id,
          source_account_code: "5100", valid_from: "2026-04-01"
        }, receivers: [ { cost_center_id: @receiver_one.id, weight_basis_points: 9999 } ]
      )
    end
    assert_match(/exactly 100%/, error.message)
  end

  private

  def create_center(code, name)
    Controlling::Manage.create_cost_center!(
      tenant: @org.tenant, actor: @org.user,
      attributes: { code: code, name: name, profit_center_id: @profit.id, valid_from: "2026-04-01" }
    )
  end

  def post_expense(amount_minor)
    snapshot = Controlling::Dimensions.snapshot(@sender, on: "2026-08-10")
    document = Documents::BuildDraft.call(
      tenant: @org.tenant, doc_type: "JV", document_date: "2026-08-10",
      posting_date: "2026-08-10", narration: "Admin expense", lines: [
        { account_code: "5100", amount_minor: amount_minor, currency: "INR",
          extra: { "controlling" => snapshot } },
        { account_code: "1000", amount_minor: -amount_minor, currency: "INR" }
      ]
    )
    Documents::Post.call(document, actor: "u:#{@org.user.id}", authorize: { user: @org.user })
    document.reload
  end

  def run_cycle(mode, key)
    Controlling::RunAllocation.call(
      cycle: @cycle, actor: @org.user,
      attributes: {
        through_date: "2026-08-31", posting_date: "2026-08-31",
        mode: mode, idempotency_key: key
      }
    )
  end
end
