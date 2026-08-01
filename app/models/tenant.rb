# frozen_string_literal: true

# An organisation — the boundary every ledger row is scoped to via tenant_id. A user reaches
# a tenant ONLY through a membership; that is what makes cross-tenant isolation enforceable.
class Tenant < ApplicationRecord
  attr_readonly :khata_workspace_id

  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships

  validates :name, :slug, :functional_currency, :time_zone, presence: true
  validates :slug, uniqueness: true
  validate :time_zone_must_be_valid

  def self.enterable_by(user)
    role_tenant_ids = UserOfficeRole.where(user_id: user.id, office_id: nil).select(:tenant_id)
    joins(:memberships)
      .where(memberships: { user_id: user.id })
      .where(id: role_tenant_ids)
      .distinct
  end

  def business_date(at: Time.current)
    at.in_time_zone(time_zone).to_date
  end

  private

  def time_zone_must_be_valid
    Time.find_zone!(time_zone) if time_zone.present?
  rescue ArgumentError
    errors.add(:time_zone, "is not recognized")
  end
end
