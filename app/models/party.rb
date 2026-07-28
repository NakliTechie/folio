# frozen_string_literal: true

# The parties spine. A single party may hold several roles (customer, vendor, employee).
# party_number is stable and human-meaningful so a .khata/Tally import keeps its codes.
class Party < ApplicationRecord
  has_many :party_roles, dependent: :destroy
  validates :tenant_id, :party_number, :name, presence: true
end
