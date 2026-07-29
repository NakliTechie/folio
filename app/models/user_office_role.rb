# frozen_string_literal: true

# Assigns a user a role, optionally scoped to ONE office (README §6: roles are per-office;
# office_id nil = tenant-wide). Carries the posting limit in force for that assignment.
class UserOfficeRole < ApplicationRecord
  belongs_to :user
  belongs_to :role_template
  belongs_to :posting_limit, optional: true
  validates :tenant_id, presence: true
end
