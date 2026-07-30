# frozen_string_literal: true

class AddDeliveryTrackingToOnboarding < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :verification_delivery_state, :string, null: false, default: "not_sent"
    add_column :users, :verification_delivery_attempted_at, :datetime

    add_column :invitations, :delivery_state, :string, null: false, default: "not_sent"
    add_column :invitations, :delivery_attempted_at, :datetime

    remove_index :invitations, column: %i[tenant_id email]
    add_index :invitations, %i[tenant_id email], unique: true, where: "accepted_at IS NULL",
      name: "index_invitations_on_one_pending_email"
  end
end
