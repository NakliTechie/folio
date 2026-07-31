# frozen_string_literal: true

# A place, belonging to an entity. Carries no GSTIN — registrations live in
# tax_registrations, because one office may hold several and many offices may share one.
class Office < ApplicationRecord
  belongs_to :entity
  has_many :office_tax_registrations, dependent: :restrict_with_exception
  has_many :tax_registrations, through: :office_tax_registrations
  validates :tenant_id, :code, :name, presence: true
end
