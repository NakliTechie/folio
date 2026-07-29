# frozen_string_literal: true

# The link that grants a user access to a tenant. Roles attach here in M2.3.
class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :tenant

  validates :user_id, uniqueness: { scope: :tenant_id }
end
