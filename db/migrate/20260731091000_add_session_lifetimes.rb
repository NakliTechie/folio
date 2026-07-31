# frozen_string_literal: true

class AddSessionLifetimes < ActiveRecord::Migration[8.1]
  def up
    add_column :sessions, :last_seen_at, :datetime
    add_column :sessions, :expires_at, :datetime

    execute <<~SQL.squish
      UPDATE sessions
      SET last_seen_at = CURRENT_TIMESTAMP,
          expires_at = CURRENT_TIMESTAMP + INTERVAL '24 hours'
    SQL

    change_column_null :sessions, :last_seen_at, false
    change_column_null :sessions, :expires_at, false
    add_index :sessions, :expires_at
  end

  def down
    remove_index :sessions, :expires_at
    remove_column :sessions, :expires_at
    remove_column :sessions, :last_seen_at
  end
end
