# frozen_string_literal: true

# Batch 9: per-user ECDSA P-256 keys. Event rows retain the exact key version used so future
# rotation never makes historical signatures unverifiable. Private material is encrypted with an
# application-derived AEAD key; plaintext never reaches the database or event payload.
class CreateUserSigningKeys < ActiveRecord::Migration[8.1]
  def up
    create_table :user_signing_keys do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :key_version, null: false, default: 1
      t.string :algorithm, null: false, default: "ecdsa-p256-sha256"
      t.text :public_key_pem, null: false
      t.text :encrypted_private_key, null: false
      t.string :fingerprint, null: false
      t.boolean :active, null: false, default: true
      t.datetime :retired_at
      t.timestamps
    end
    add_index :user_signing_keys, %i[user_id key_version], unique: true
    add_index :user_signing_keys, :fingerprint, unique: true
    add_index :user_signing_keys, :user_id, unique: true, where: "active = TRUE",
      name: "index_user_signing_keys_on_active_user"
    add_check_constraint :user_signing_keys, "key_version > 0",
      name: "user_signing_keys_version_positive"
    add_check_constraint :user_signing_keys,
      "algorithm IN ('ecdsa-p256-sha256')", name: "user_signing_keys_algorithm_valid"

    add_column :ledger_events, :signing_key_id, :bigint
    add_column :domain_events, :signing_key_id, :bigint
    add_index :ledger_events, :signing_key_id
    add_index :domain_events, :signing_key_id

    # Existing users receive keys immediately. Historical events intentionally remain unsigned;
    # retroactively signing a stored hash would misrepresent who signed at posting time.
    User.find_each { |user| EventSigning::KeyProvisioner.ensure!(user) }
  end

  def down
    remove_index :domain_events, :signing_key_id
    remove_index :ledger_events, :signing_key_id
    remove_column :domain_events, :signing_key_id
    remove_column :ledger_events, :signing_key_id
    drop_table :user_signing_keys
  end
end
