# frozen_string_literal: true

# A statutory number series (spec §8). NOT a Postgres sequence — a sequence does not roll
# back and is gap-prone. `allocate!` hands out the next value under a row lock
# (SELECT ... FOR UPDATE) inside the caller's posting transaction, so concurrent posts to
# the same series serialise and the series stays gapless.
class NumberRange < ApplicationRecord
  SERIES_KEY = %i[tenant_id entity_id office_id doc_type fiscal_year].freeze

  validates :tenant_id, :entity_id, :office_id, :doc_type, :fiscal_year, :next_value,
            presence: true

  # Allocate the next value in the series, gaplessly. Must run inside a transaction; the
  # row lock is what serialises two concurrent allocators. Raises if the series row does
  # not exist — statutory ranges are provisioned deliberately, not conjured mid-post.
  def self.allocate!(tenant_id:, entity_id:, office_id:, doc_type:, fiscal_year:)
    transaction(requires_new: true) do
      row = lock.find_by!(
        tenant_id: tenant_id, entity_id: entity_id, office_id: office_id,
        doc_type: doc_type, fiscal_year: fiscal_year
      )
      value = row.next_value
      row.update!(next_value: value + 1)
      value
    end
  end
end
