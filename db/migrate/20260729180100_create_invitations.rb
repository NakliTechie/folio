# frozen_string_literal: true

# Onboarding — the invite path. An owner invites an email into their tenant with a role; the
# invitee accepts via a signed token to create their User + Membership + role. accepted_at
# makes it single-use.
class CreateInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :invitations do |t|
      t.bigint  :tenant_id,   null: false
      t.string  :email,       null: false
      t.string  :role_code,   null: false            # owner/accountant/operator/ca_auditor/viewer
      t.bigint  :invited_by_id                        # the User who invited
      t.datetime :accepted_at
      t.timestamps
    end
    add_index :invitations, [ :tenant_id, :email ]
  end
end
