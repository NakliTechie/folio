# frozen_string_literal: true

class ContractNumberRange < ApplicationRecord
  SERIES_KEY = %i[tenant_id entity_id office_id fiscal_year].freeze

  validates :tenant_id, :entity_id, :office_id, :fiscal_year, :next_value, presence: true
  validates :next_value, numericality: { only_integer: true, greater_than: 0 }

  def self.allocate!(tenant_id:, entity_id:, office_id:, fiscal_year:)
    key = { tenant_id: tenant_id, entity_id: entity_id, office_id: office_id, fiscal_year: fiscal_year }
    transaction(requires_new: true) do
      begin
        find_or_create_by!(key) { |range| range.next_value = 1 }
      rescue ActiveRecord::RecordNotUnique
        # A concurrent creator won; the locked lookup below is authoritative.
      end
      range = lock.find_by!(key)
      value = range.next_value
      range.update!(next_value: value + 1)
      value
    end
  end
end
