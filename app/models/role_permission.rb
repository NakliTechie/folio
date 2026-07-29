# frozen_string_literal: true

# One cell of the RBAC matrix: this role grants this capability.
class RolePermission < ApplicationRecord
  belongs_to :role_template
  validates :capability, presence: true
end
