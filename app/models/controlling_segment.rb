# frozen_string_literal: true

class ControllingSegment < ApplicationRecord
  has_many :profit_centers, dependent: :restrict_with_exception

  normalizes :code, with: ->(value) { value.to_s.strip.upcase }
  validates :tenant_id, :code, :name, presence: true
  validates :code, uniqueness: { scope: :tenant_id }
  scope :active, -> { where(active: true) }
end
