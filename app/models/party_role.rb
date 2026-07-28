# frozen_string_literal: true

class PartyRole < ApplicationRecord
  belongs_to :party
  ROLES = %w[customer vendor employee].freeze
  validates :role, presence: true, inclusion: { in: ROLES }
end
