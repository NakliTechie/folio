# frozen_string_literal: true

module Folio
  module TenantContext
    module_function

    def activate!(tenant_id, connection: ActiveRecord::Base.connection)
      id = Integer(tenant_id)
      connection.execute(
        ActiveRecord::Base.sanitize_sql_array(
          [ "SELECT set_config('folio.tenant_id', ?, false) AS tenant_id", id.to_s ]
        )
      ).first.fetch("tenant_id")
    end

    def clear!(connection: nil)
      return unless ActiveRecord::Base.connected?

      (connection || ActiveRecord::Base.connection)
        .execute("SELECT set_config('folio.tenant_id', '', false)")
    end

    def current(connection: ActiveRecord::Base.connection)
      connection.execute(<<~SQL.squish).first.fetch("tenant_id")
        SELECT NULLIF(current_setting('folio.tenant_id', true), '') AS tenant_id
      SQL
    end

    def with(tenant_id)
      connection = ActiveRecord::Base.connection
      previous = current(connection: connection)
      activate!(tenant_id, connection: connection)
      yield
    ensure
      if previous.present?
        activate!(previous, connection: connection)
      else
        clear!(connection: connection)
      end
    end
  end
end
