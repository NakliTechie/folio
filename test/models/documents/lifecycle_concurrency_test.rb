# frozen_string_literal: true

require "test_helper"
require "securerandom"

# Real competing database connections. Transactional tests are disabled because each thread
# must see committed setup rows and contend on the same Document row lock.
class Documents::LifecycleConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  JUN1 = Date.new(2025, 6, 1)

  setup do
    token = SecureRandom.hex(8)
    @tenant = Tenant.create!(name: "Concurrency #{token}", slug: "concurrency-#{token}")
    Onboarding::Seeds.org_spine!(@tenant)
    @type = DocumentType.create!(tenant_id: @tenant.id, code: "JV", label: "Journal Voucher",
      posting_rule: "journal_voucher", number_prefix: "JV/")
    Account.create!(tenant_id: @tenant.id, code: "1000", name: "Cash", account_type: "asset")
    Account.create!(tenant_id: @tenant.id, code: "4000", name: "Sales", account_type: "income")
  end

  def build_jv
    entity = Entity.find_by!(tenant_id: @tenant.id, code: "PRIMARY")
    office = Office.find_by!(tenant_id: @tenant.id, code: "PRIMARY")
    Document.create!(
      tenant_id: @tenant.id, entity_id: entity.id, office_id: office.id, doc_type: "JV",
      document_type_id: @type.id, fiscal_year: 2025, document_date: JUN1, posting_date: JUN1,
      state: "draft", narration: "concurrency probe"
    ).tap do |document|
      document.document_lines.create!(
        tenant_id: @tenant.id, line_no: 1, account_code: "1000", amount_minor: 100_000
      )
      document.document_lines.create!(
        tenant_id: @tenant.id, line_no: 2, account_code: "4000", amount_minor: -100_000
      )
    end
  end

  def race
    ready = Queue.new
    start = Queue.new
    outcomes = Array.new(2)
    threads = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          outcomes[index] = yield(index)
        rescue StandardError => e
          outcomes[index] = e
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each(&:join)
    outcomes
  end

  test "two concurrent posts emit one entry and one statutory number" do
    document = build_jv

    outcomes = race do |index|
      Documents::Post.call(Document.find(document.id), actor: "thread:#{index}")
    end

    assert_equal 1, outcomes.count { |outcome| outcome.is_a?(Entry) }
    assert_equal [ Documents::Post::NotPostable ], outcomes.grep(Exception).map(&:class)
    assert_equal "posted", document.reload.state
    assert_equal 1, Entry.where(tenant_id: @tenant.id, document_id: document.id).count
    assert_equal 1, LedgerEvent.for_tenant(@tenant.id).where(action: "entry.posted").count
    assert_equal 2, NumberRange.find_by!(tenant_id: @tenant.id, doc_type: "JV").next_value
  end

  test "two concurrent reversals emit one compensating document" do
    document = build_jv
    Documents::Post.call(document, actor: "setup")

    outcomes = race do |index|
      Documents::Reverse.call(Document.find(document.id), actor: "thread:#{index}")
    end

    assert_equal 1, outcomes.count { |outcome| outcome.is_a?(Entry) }
    assert_equal [ Documents::Reverse::NotReversible ], outcomes.grep(Exception).map(&:class)
    assert_equal "reversed", document.reload.state
    assert_equal 1, Document.where(tenant_id: @tenant.id, reverses_document_id: document.id).count
    assert_equal 2, LedgerEvent.for_tenant(@tenant.id).where(action: "entry.posted").count
  end
end
