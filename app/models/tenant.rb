# frozen_string_literal: true

# An organisation — the boundary every ledger row is scoped to via tenant_id. A user reaches
# a tenant ONLY through a membership; that is what makes cross-tenant isolation enforceable.
class Tenant < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships

  validates :name, :slug, :functional_currency, presence: true
  validates :slug, uniqueness: true
end
