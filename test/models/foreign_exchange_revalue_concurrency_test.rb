# frozen_string_literal: true

require "test_helper"
require "securerandom"

class ForeignExchangeRevalueConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    token = SecureRandom.hex(8)
    @tenant = Tenant.create!(
      id: 6_600_000_000 + SecureRandom.random_number(100_000_000),
      name: "FX Race #{token}", slug: "fx-race-#{token}"
    )
    Onboarding::Seeds.org_spine!(@tenant)
    Onboarding::Seeds.chart_of_accounts!(@tenant)
    Onboarding::Seeds.document_types!(@tenant)
    Rbac::Presets.seed_for!(@tenant)
    @user = users(:one)
    Membership.create!(tenant: @tenant, user: @user)
    UserOfficeRole.create!(
      tenant_id: @tenant.id, user: @user, office_id: nil,
      role_template: Rbac::Presets.role_for(@tenant, "owner")
    )
    EventSigning::KeyProvisioner.ensure!(@user)
    ForeignExchange::Rates.create!(
      tenant: @tenant, actor: @user,
      attributes: {
        from_currency: "JPY", to_currency: "INR", effective_on: Date.new(2026, 8, 1),
        rate: "0.55", rate_type: "spot", source: "Approved treasury feed"
      }
    )
    ForeignExchange::Rates.create!(
      tenant: @tenant, actor: @user,
      attributes: {
        from_currency: "JPY", to_currency: "INR", effective_on: Date.new(2026, 8, 31),
        rate: "0.60", rate_type: "closing", source: "Approved treasury feed"
      }
    )
    document = Documents::BuildDraft.call(
      tenant: @tenant, doc_type: "JV",
      document_date: Date.new(2026, 8, 1), posting_date: Date.new(2026, 8, 1),
      narration: "JPY bank funding",
      lines: [
        { account_code: "1010", amount_minor: 1_000, currency: "JPY" },
        { account_code: "3000", amount_minor: -1_000, currency: "JPY" }
      ]
    )
    Documents::Post.call(
      document, actor: "u:#{@user.id}", authorize: { user: @user }
    )
  end

  test "same-key concurrent posting returns one run and appends one adjustment" do
    before_events = LedgerEvent.for_tenant(@tenant.id).count
    ready = Queue.new
    start = Queue.new
    outcomes = Array.new(2)
    threads = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          outcomes[index] = ForeignExchange::Revalue.call(
            tenant: Tenant.find(@tenant.id), actor: User.find(@user.id),
            revaluation_date: Date.new(2026, 8, 31), mode: "post",
            idempotency_key: "shared-fx-key"
          )
        rescue StandardError => e
          outcomes[index] = e
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each(&:join)

    assert outcomes.all? { |outcome| outcome.is_a?(ExchangeRevaluationRun) }, outcomes.inspect
    assert_equal 1, outcomes.map(&:id).uniq.size
    assert_equal "posted", outcomes.first.reload.status
    assert_equal before_events + 1, LedgerEvent.for_tenant(@tenant.id).count
    assert_equal 1, ExchangeRevaluationRun.where(
      tenant_id: @tenant.id, idempotency_key: "shared-fx-key"
    ).count
  end
end
