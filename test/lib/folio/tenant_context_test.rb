# frozen_string_literal: true

require "test_helper"

class Folio::TenantContextTest < ActiveSupport::TestCase
  test "nested tenant contexts restore the previous database setting" do
    Folio::TenantContext.clear!

    Folio::TenantContext.with(101) do
      assert_equal "101", Folio::TenantContext.current

      Folio::TenantContext.with(202) do
        assert_equal "202", Folio::TenantContext.current
      end

      assert_equal "101", Folio::TenantContext.current
    end

    assert_nil Folio::TenantContext.current
  ensure
    Folio::TenantContext.clear!
  end

  test "business tables have forced tenant isolation while control-plane tables do not" do
    connection = ActiveRecord::Base.connection

    account = connection.select_one(<<~SQL.squish)
      SELECT relrowsecurity, relforcerowsecurity
      FROM pg_class
      WHERE oid = 'public.accounts'::regclass
    SQL
    membership = connection.select_one(<<~SQL.squish)
      SELECT relrowsecurity, relforcerowsecurity
      FROM pg_class
      WHERE oid = 'public.memberships'::regclass
    SQL
    policies = connection.select_value(<<~SQL.squish)
      SELECT COUNT(*)
      FROM pg_policies
      WHERE schemaname = 'public'
        AND policyname = 'folio_tenant_isolation'
    SQL

    assert ActiveModel::Type::Boolean.new.cast(account.fetch("relrowsecurity"))
    assert ActiveModel::Type::Boolean.new.cast(account.fetch("relforcerowsecurity"))
    assert_not ActiveModel::Type::Boolean.new.cast(membership.fetch("relrowsecurity"))
    assert_not ActiveModel::Type::Boolean.new.cast(membership.fetch("relforcerowsecurity"))
    assert_operator policies.to_i, :>, 0
  end
end
