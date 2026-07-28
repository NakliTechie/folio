# frozen_string_literal: true

# A legal person — its own functional currency, fiscal-year variant and jurisdiction.
# Distinct from an office (a place). One entity has many offices; consolidating those
# is a GROUP BY. A group has many entities; consolidating those needs elimination.
class Entity < ApplicationRecord
  has_many :offices, dependent: :restrict_with_exception
  has_many :tax_registrations, dependent: :restrict_with_exception

  validates :tenant_id, :code, :legal_name, :functional_currency, :fiscal_year_variant,
            :jurisdiction_profile, presence: true
  validates :functional_currency, length: { is: 3 }
  validates :jurisdiction_profile, inclusion: { in: %w[IN DE UK US MY] }
end
