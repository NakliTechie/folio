# frozen_string_literal: true

# An amount ceiling an authority may post up to (spec §11: the threshold in force is part of
# the authority). nil on a user_office_role means unlimited.
class PostingLimit < ApplicationRecord
  validates :tenant_id, :name, :amount_minor, presence: true
end
