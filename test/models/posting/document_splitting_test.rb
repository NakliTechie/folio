# frozen_string_literal: true

require "test_helper"

class Posting::DocumentSplittingTest < ActiveSupport::TestCase
  test "technical clearing lines make every profit-center and segment slice balance exactly" do
    lines = [
      line(1, "1000", -10_001),
      line(2, "5100", 3_333, profit_center_id: 10, segment_id: 100),
      line(3, "5100", 6_668, profit_center_id: 20, segment_id: 200)
    ]

    split = Posting::DocumentSplitting.apply(lines)

    assert_equal 6, split.size
    assert_empty Posting::PostEntry.balance_offenders(split)
    assert_empty Posting::DocumentSplitting.per_dimension_offenders(split)
    technical = split.drop(3)
    assert_equal [ "2990", "2990", "2990" ], technical.pluck(:account_code)
    assert_equal [ 10_001, -3_333, -6_668 ],
      technical.map { |row| row.fetch(:amounts).sole.fetch(:amount_minor) }
    assert_equal [ [ 1 ], [ 2 ], [ 3 ] ],
      technical.map { |row| row.dig(:extra, "documentSplitting", "sourceLineNumbers") }
  end

  test "post and replay preserve split and partner provenance" do
    org = Onboarding::SignUp.call(
      email: "splitting@folio.invalid", password: "correct-horse-battery",
      org_name: "Document Splitting"
    )
    entity = Entity.find_by!(tenant_id: org.tenant.id, code: "PRIMARY")
    office = Office.find_by!(tenant_id: org.tenant.id, code: "PRIMARY")
    ledger = Ledger.find_by!(tenant_id: org.tenant.id, code: "PRIMARY")
    segment = ControllingSegment.find_by!(tenant_id: org.tenant.id, code: "UNASSIGNED")
    profit = ProfitCenter.find_by!(tenant_id: org.tenant.id, code: "UNASSIGNED")

    entry = Posting::PostEntry.post!(
      tenant_id: org.tenant.id, actor: "u:#{org.user.id}", actor_user_id: org.user.id,
      document_date: Date.new(2026, 8, 1), posting_date: Date.new(2026, 8, 1),
      entered_at: Time.current, fiscal_year: 2026, period_no: 5,
      lines: [
        line(1, "1000", -1_000, ledger_id: ledger.id, entity_id: entity.id, office_id: office.id,
          partner_entity_id: entity.id, partner_profit_center_id: profit.id,
          partner_segment_id: segment.id, intercompany_transaction_id: "IC-1"),
        line(2, "5100", 1_000, ledger_id: ledger.id, entity_id: entity.id, office_id: office.id,
          profit_center_id: profit.id, segment_id: segment.id)
      ]
    )

    original = entry.entry_lines.find_by!(line_no: 1)
    assert_equal [ entity.id, profit.id, segment.id, "IC-1" ],
      original.values_at(
        :partner_entity_id, :partner_profit_center_id, :partner_segment_id,
        :intercompany_transaction_id
      )
    assert_equal 2, entry.entry_lines.where(split_kind: "zero_balance").count
    event = LedgerEvent.find(entry.ledger_event_id)
    entry.destroy!
    replay = Posting::PostEntry.replay!(event)
    assert_equal 2, replay.entry_lines.where(split_kind: "zero_balance").count
    assert_empty Posting::DocumentSplitting.per_dimension_offenders(
      replay.entry_lines.includes(:amounts).map { |record| replay_line(record) }
    )
  end

  private

  def line(number, account, amount, **attributes)
    {
      line_no: number, account_code: account,
      ledger_id: attributes.delete(:ledger_id) || 1,
      entity_id: attributes.delete(:entity_id) || 1,
      office_id: attributes.delete(:office_id) || 1,
      amounts: [ {
        slot_role: "transaction", currency: "INR", minor_unit_exponent: 2,
        amount_minor: amount
      } ]
    }.merge(attributes)
  end

  def replay_line(record)
    record.attributes.symbolize_keys.slice(
      :line_no, :account_code, :ledger_id, :entity_id, :office_id,
      :profit_center_id, :segment_id, :posting_layer, :split_kind
    ).merge(amounts: record.amounts.map do |amount|
      amount.attributes.symbolize_keys.slice(
        :slot_role, :currency, :minor_unit_exponent, :amount_minor
      )
    end)
  end
end
