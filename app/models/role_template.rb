# frozen_string_literal: true

# A named role. Its capabilities are the role_permissions rows (the matrix), so adding a
# capability to a role is data, not a code change.
class RoleTemplate < ApplicationRecord
  has_many :role_permissions, dependent: :destroy
  has_many :user_office_roles, dependent: :restrict_with_exception

  validates :code, :name, presence: true

  def capabilities
    role_permissions.pluck(:capability)
  end

  # "*" is the owner wildcard.
  def permits?(capability)
    caps = capabilities
    caps.include?("*") || caps.include?(capability)
  end
end
