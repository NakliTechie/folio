# frozen_string_literal: true

module Folio
  module DatabaseTrustBoundary
    module_function

    def call(connection)
      row = connection.select_one(<<~SQL.squish)
        SELECT current_user AS role_name,
               roles.rolsuper AS superuser,
               roles.rolcreatedb AS creates_databases,
               roles.rolcreaterole AS creates_roles,
               has_schema_privilege(current_user, 'public', 'CREATE') AS creates_in_public,
               EXISTS (
                 SELECT 1 FROM pg_class tables
                 JOIN pg_namespace schemas ON schemas.oid = tables.relnamespace
                 WHERE schemas.nspname = 'public'
                   AND tables.relkind IN ('r', 'p')
                   AND pg_get_userbyid(tables.relowner) = current_user
               ) AS owns_tables
        FROM pg_roles roles
        WHERE roles.rolname = current_user
      SQL
      unsafe = %w[superuser creates_databases creates_roles creates_in_public owns_tables]
        .select { |key| ActiveModel::Type::Boolean.new.cast(row.fetch(key)) }
      { status: unsafe.empty? ? "ok" : "unsafe", role: row.fetch("role_name"), unsafe: unsafe }
    end
  end
end
