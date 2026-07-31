# frozen_string_literal: true

require "test_helper"
require "securerandom"
require "timeout"

# Real competing connections. Rebuild pauses after taking the tenant lock; a writer must
# remain blocked until the rebuilt projection is committed, then project its event once.
class Posting::RebuildConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @tenant_id = 8_000_000_000 + SecureRandom.random_number(1_000_000_000)
    @first = Posting::PostEntry.post!(draft(on: Date.new(2026, 7, 31), amount: 100))
  end

  test "a concurrent post waits for rebuild and every event has exactly one projection" do
    paused = Queue.new
    resume = Queue.new
    writer_started = Queue.new
    original_project = Posting.method(:project!)
    first_event_id = @first.ledger_event_id
    outcomes = {}

    project_with_pause = lambda do |event|
      if event.id == first_event_id
        paused << true
        resume.pop
      end
      original_project.call(event)
    end

    rebuild = nil
    writer = nil
    Posting.define_singleton_method(:project!, project_with_pause)
    begin
      rebuild = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          outcomes[:rebuild] = Posting.rebuild!(@tenant_id)
        rescue StandardError => error
          outcomes[:rebuild] = error
        end
      end
      if rebuild.join(0.1)
        raise outcomes[:rebuild] if outcomes[:rebuild].is_a?(Exception)
        flunk "rebuild completed before the projection pause"
      end
      Timeout.timeout(5) { paused.pop }

      writer = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          writer_started << true
          outcomes[:writer] = Posting::PostEntry.post!(
            draft(on: Date.new(2026, 8, 1), amount: 25)
          )
        rescue StandardError => error
          outcomes[:writer] = error
        end
      end
      Timeout.timeout(5) { writer_started.pop }

      refute writer.join(0.2), "the writer must wait while rebuild holds the tenant event lock"
      resume << true
      Timeout.timeout(5) { rebuild.join }
      Timeout.timeout(5) { writer.join }
    ensure
      resume << true
      rebuild&.join(1)
      writer&.join(1)
      Posting.define_singleton_method(:project!, original_project)
    end

    refute_kind_of Exception, outcomes[:rebuild]
    assert_instance_of Entry, outcomes[:writer]
    assert_equal 2, LedgerEvent.for_tenant(@tenant_id).count
    assert_equal 2, Entry.where(tenant_id: @tenant_id).count
    assert Entry.where(tenant_id: @tenant_id).group(:ledger_event_id).count.values.all? { |count| count == 1 }
    assert LedgerEvent.verify_chain(@tenant_id).fetch(:ok)
  end

  private

  def draft(on:, amount:)
    {
      tenant_id: @tenant_id, actor: "rebuild-race", origin: "test",
      document_date: on, posting_date: on, entered_at: on.to_time,
      fiscal_year: 2026, period_no: 4,
      lines: [
        { line_no: 1, account_code: "1000", ledger_id: 1, entity_id: 1, office_id: 1,
          amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2,
                       amount_minor: amount } ] },
        { line_no: 2, account_code: "4000", ledger_id: 1, entity_id: 1, office_id: 1,
          amounts: [ { slot_role: "transaction", currency: "INR", minor_unit_exponent: 2,
                       amount_minor: -amount } ] }
      ]
    }
  end
end
