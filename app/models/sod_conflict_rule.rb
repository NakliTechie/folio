# frozen_string_literal: true

class SodConflictRule < ApplicationRecord
  SEVERITIES = %w[critical high medium low].freeze

  belongs_to :tenant

  validates :code, :name, :capability_a, :capability_b, :description, :remediation, presence: true
  validates :code, uniqueness: { scope: :tenant_id }
  validates :severity, inclusion: { in: SEVERITIES }
  validate :capabilities_are_distinct

  private

  def capabilities_are_distinct
    errors.add(:capability_b, "must differ from the first capability") if capability_a == capability_b
  end
end
