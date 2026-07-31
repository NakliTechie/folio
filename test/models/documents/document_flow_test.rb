# frozen_string_literal: true

require "test_helper"

# Batch 4 — the document-centric flow: create → simulate → post → trial balance → reverse →
# TB returns, and the chain still verifies. Reversal is a compensating document, never a delete.
class Documents::DocumentFlowTest < ActiveSupport::TestCase
  TENANT = 91
  JUN1 = Date.new(2025, 6, 1)

  setup do
    @tenant = Tenant.create!(id: TENANT, name: "Document Flow", slug: "document-flow")
    spine = Onboarding::Seeds.org_spine!(@tenant)
    @entity = spine.fetch(:entity)
    @office = spine.fetch(:office)
    @type = DocumentType.create!(tenant_id: TENANT, code: "JV", label: "Journal Voucher",
      posting_rule: "journal_voucher", number_prefix: "JV/")
    Account.create!(tenant_id: TENANT, code: "1000", name: "Cash", account_type: "asset")
    Account.create!(tenant_id: TENANT, code: "4000", name: "Sales", account_type: "income")
  end

  def build_jv(amount: 100_000)
    doc = Document.create!(tenant_id: TENANT, entity_id: @entity.id, office_id: @office.id, doc_type: "JV",
      document_type_id: @type.id, fiscal_year: 2025, document_date: JUN1, posting_date: JUN1,
      state: "draft", narration: "test JV")
    doc.document_lines.create!(tenant_id: TENANT, line_no: 1, account_code: "1000", amount_minor: amount)   # Dr Cash
    doc.document_lines.create!(tenant_id: TENANT, line_no: 2, account_code: "4000", amount_minor: -amount)  # Cr Sales
    doc
  end

  test "simulate previews the entry and writes nothing" do
    doc = build_jv
    sim = Documents::Simulate.call(doc)
    assert sim[:balanced]
    assert_equal 2, sim[:lines].size
    assert_equal 0, LedgerEvent.for_tenant(TENANT).count, "simulate posts nothing"
    assert_equal "draft", doc.reload.state
  end

  test "an unbalanced document is rejected at post, writing nothing" do
    doc = build_jv
    doc.document_lines.first.update!(amount_minor: 99_999)
    assert_raises(Posting::UnbalancedError) { Documents::Post.call(doc, actor: "u:1") }
    assert_equal "draft", doc.reload.state
    assert_equal 0, Entry.where(tenant_id: TENANT).count
    assert_nil NumberRange.find_by(tenant_id: TENANT, doc_type: "JV"), "an unbalanced doc never allocates a number"
  end

  test "empty documents and wrong fiscal identities are rejected before number allocation" do
    empty = Document.create!(tenant_id: TENANT, entity_id: @entity.id, office_id: @office.id,
      doc_type: "JV", document_type: @type, fiscal_year: 2025,
      document_date: JUN1, posting_date: JUN1, state: "draft")

    assert_raises(Documents::InvalidDocument) { Documents::Post.call(empty, actor: "u") }
    assert_nil NumberRange.find_by(tenant_id: TENANT, doc_type: "JV")

    wrong_year = build_jv
    wrong_year.update!(fiscal_year: 1999)
    error = assert_raises(Documents::InvalidDocument) { Documents::Post.call(wrong_year, actor: "u") }
    assert_match(/expected 2025/, error.message)
    assert_nil NumberRange.find_by(tenant_id: TENANT, doc_type: "JV")
  end

  test "posting rejects currency metadata that does not match the tenant profile" do
    doc = build_jv
    doc.document_lines.update_all(currency: "USD", minor_unit_exponent: 0)

    error = assert_raises(Documents::InvalidDocument) { Documents::Post.call(doc, actor: "u") }
    assert_match(/must use INR with minor-unit exponent 2/, error.message)
    assert_nil NumberRange.find_by(tenant_id: TENANT, doc_type: "JV")
  end

  test "invalid text amounts cast to zero but fail line validation" do
    line = DocumentLine.new(tenant_id: TENANT, document: build_jv,
      line_no: 3, account_code: "1000", amount_minor: "not-a-number")

    refute line.valid?
    assert_includes line.errors[:amount_minor], "is not a number"
  end

  test "create → simulate → post → trial balance → reverse → TB returns, chain verifies" do
    doc = build_jv(amount: 100_000)
    assert Documents::Simulate.call(doc)[:balanced]

    entry = Documents::Post.call(doc, actor: "u:1")
    assert_equal "posted", doc.reload.state
    assert_equal "JV/1", doc.document_number
    assert_equal entry.id, doc.posted_entry_id

    tb = Reports.trial_balance(TENANT).index_by { |r| r["name"] }
    assert_equal 100_000, tb["Cash"]["debit"]
    assert_equal 100_000, tb["Sales"]["credit"]
    assert LedgerEvent.verify_chain(TENANT)[:ok]

    Documents::Reverse.call(doc, actor: "u:1")
    assert_equal "reversed", doc.reload.state
    rev = doc.reversed_by
    assert_equal doc.id, rev.reverses_document_id
    assert_equal "posted", rev.state

    tb2 = Reports.trial_balance(TENANT).index_by { |r| r["name"] }
    assert_equal 0, tb2["Cash"]["debit"] - tb2["Cash"]["credit"], "Cash nets to zero after reversal"
    assert_equal 0, tb2["Sales"]["debit"] - tb2["Sales"]["credit"], "Sales nets to zero after reversal"
    assert LedgerEvent.verify_chain(TENANT)[:ok], "the chain still verifies after the reversal"
    assert_equal 2, Document.where(tenant_id: TENANT).count, "reversal ADDS a document, deletes none"
  end

  test "a reversal is recorded as a NEGATIVE posting, not a naive counter-posting (§7)" do
    doc = build_jv(amount: 100_000)
    Documents::Post.call(doc, actor: "u")
    Documents::Reverse.call(doc, actor: "u")

    rev_entry = Entry.find(doc.reversed_by.posted_entry_id)
    # The reversal keeps the same accounts with negated amounts, and every line is flagged
    # is_negative_posting — so turnover is recoverable, not permanently inflated.
    assert rev_entry.entry_lines.all?(&:is_negative_posting),
      "every reversal line must set is_negative_posting (§7 — unrecoverable once on the log)"
    assert_equal %w[1000 4000], rev_entry.entry_lines.order(:line_no).pluck(:account_code),
      "a reversal is a same-account negative posting, not a counter-posting to the opposite account"
    # the original post is NOT a negative posting
    assert Entry.find(doc.posted_entry_id).entry_lines.none?(&:is_negative_posting)
  end

  test "a deactivated account can be used only by its linked reversal" do
    doc = build_jv(amount: 100_000)
    Documents::Post.call(doc, actor: "u")
    Account.find_by!(tenant_id: TENANT, code: "1000").update!(active: false)

    Documents::Reverse.call(doc, actor: "u")
    assert_equal "reversed", doc.reload.state

    new_document = build_jv
    assert_raises(Documents::Post::InactiveAccount) do
      Documents::Post.call(new_document, actor: "u")
    end
  end

  test "an inactive document type blocks new posts but not a linked reversal" do
    original = build_jv(amount: 100_000)
    Documents::Post.call(original, actor: "u")
    @type.update!(active: false)

    new_document = build_jv
    error = assert_raises(Documents::InvalidDocument) do
      Documents::Post.call(new_document, actor: "u")
    end
    assert_match(/document type is unavailable/, error.message)

    Documents::Reverse.call(original, actor: "u")
    assert_equal "reversed", original.reload.state
  end

  test "lifecycle: a reversed document cannot be reversed again; a draft cannot be reversed" do
    draft = build_jv
    assert_raises(Documents::Reverse::NotReversible) { Documents::Reverse.call(draft, actor: "u") }
    Documents::Post.call(draft, actor: "u")
    Documents::Reverse.call(draft, actor: "u")
    assert_raises(Documents::Reverse::NotReversible) { Documents::Reverse.call(draft.reload, actor: "u") }
  end

  test "posting is idempotent-guarded: a posted document cannot be posted again" do
    doc = build_jv
    Documents::Post.call(doc, actor: "u")
    assert_raises(Documents::Post::NotPostable) { Documents::Post.call(doc.reload, actor: "u") }
  end
end
