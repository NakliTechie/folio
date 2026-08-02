# frozen_string_literal: true

class AddMultiFactorAuthentication < ActiveRecord::Migration[8.1]
  def up
    change_table :users, bulk: true do |t|
      t.text :mfa_secret_ciphertext
      t.jsonb :mfa_recovery_code_digests, null: false, default: []
      t.datetime :mfa_enabled_at
    end
    add_column :sessions, :mfa_verified_at, :datetime
    execute <<~SQL
      ALTER TABLE users
        ADD CONSTRAINT chk_users_mfa_complete CHECK (
          (mfa_enabled_at IS NULL AND mfa_secret_ciphertext IS NULL AND
           jsonb_array_length(mfa_recovery_code_digests) = 0)
          OR
          (mfa_enabled_at IS NOT NULL AND mfa_secret_ciphertext IS NOT NULL AND
           jsonb_typeof(mfa_recovery_code_digests) = 'array')
        ),
        ADD CONSTRAINT chk_users_mfa_recovery_array CHECK (
          jsonb_typeof(mfa_recovery_code_digests) = 'array'
        );
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE users
        DROP CONSTRAINT IF EXISTS chk_users_mfa_complete,
        DROP CONSTRAINT IF EXISTS chk_users_mfa_recovery_array;
    SQL
    remove_column :sessions, :mfa_verified_at
    change_table :users, bulk: true do |t|
      t.remove :mfa_secret_ciphertext, :mfa_recovery_code_digests, :mfa_enabled_at
    end
  end
end
