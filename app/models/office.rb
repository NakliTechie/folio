# frozen_string_literal: true

# A place, belonging to an entity. Carries no GSTIN — registrations live in
# tax_registrations, because one office may hold several and many offices may share one.
class Office < ApplicationRecord
  belongs_to :entity
  validates :tenant_id, :code, :name, presence: true
end
