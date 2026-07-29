# frozen_string_literal: true

# Onboarding — email verification for self-signup. Soft by default (marks trust; gating
# behaviour on it is a policy decision, parked). nil = unverified.
class AddVerifiedAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :verified_at, :datetime
  end
end
