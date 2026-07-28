# frozen_string_literal: true

require "test_helper"

# Batch 4 — statutory numbers at the DOCUMENT layer: sequential posts from one series are
# gapless and unique, and a rolled-back post RETURNS its number (the reason a statutory series
# is a FOR UPDATE row, not a sequence). Transactional, because posting appends real
# ledger_events which are append-only (undeletable) — so committing them non-transactionally
# would both break cleanup and leave tenant events that trip never-degrade #1.
#
# The underlying thread-concurrency of NumberRange.allocate! (no collision, no gap under a real
# 4-thread race) is proven separately in test/models/entry_model_b31_test.rb; here we prove the
# document layer wires allocate + post ATOMICALLY.
class Documents::NumberAllocationTest < ActiveSupport::TestCase
  TENANT = 92
  JUN1 = Date.new(2025, 6, 1)

  setup do
    @type = DocumentType.create!(tenant_id: TENANT, code: "JV", label: "JV",
      posting_rule: "journal_voucher", number_prefix: "JV/")
    Account.create!(tenant_id: TENANT, code: "1000", name: "Cash", account_type: "asset")
    Account.create!(tenant_id: TENANT, code: "4000", name: "Sales", account_type: "income")
  end

  def build_jv
    doc = Document.create!(tenant_id: TENANT, entity_id: 1, office_id: 1, doc_type: "JV",
      document_type_id: @type.id, fiscal_year: 2025, document_date: JUN1, posting_date: JUN1, state: "draft")
    doc.document_lines.create!(tenant_id: TENANT, line_no: 1, account_code: "1000", amount_minor: 100_000)
    doc.document_lines.create!(tenant_id: TENANT, line_no: 2, account_code: "4000", amount_minor: -100_000)
    doc
  end

  test "sequential posts from one series get gapless, unique numbers and a valid chain" do
    4.times { Documents::Post.call(build_jv, actor: "u") }
    assert_equal %w[JV/1 JV/2 JV/3 JV/4],
      Document.where(tenant_id: TENANT, state: "posted").pluck(:document_number).sort
    assert_equal 5, NumberRange.find_by(tenant_id: TENANT, doc_type: "JV").next_value
    assert_equal 4, LedgerEvent.for_tenant(TENANT).count
    assert LedgerEvent.verify_chain(TENANT)[:ok]
  end

  test "a rolled-back post does not consume a number — the number returns, gapless" do
    Documents::Post.call(build_jv, actor: "u") # JV/1
    range = NumberRange.find_by(tenant_id: TENANT, doc_type: "JV")
    assert_equal 2, range.next_value

    # Close the period so PostEntry rejects AFTER the number is allocated inside the transaction.
    PeriodControl.create!(tenant_id: TENANT, entity_id: 1, ledger_id: 1, account_class: "ALL",
      fiscal_year: 2025, period_no: 3, state: "closed")
    assert_raises(Posting::PeriodClosedError) { Documents::Post.call(build_jv, actor: "u") }
    assert_equal 2, range.reload.next_value,
      "a rolled-back post must return the number — the reason a statutory series is not a sequence"

    # Re-open and post: the next number is JV/2 (gapless), not JV/3.
    PeriodControl.where(tenant_id: TENANT).delete_all
    doc = build_jv
    Documents::Post.call(doc, actor: "u")
    assert_equal "JV/2", doc.reload.document_number
  end
end
