# frozen_string_literal: true

# A dated, immutable-in-use presentation configuration. Reports select the active version
# effective on their end date, so a future layout change does not silently rewrite old reports.
class FinancialStatementVersion < ApplicationRecord
  STATUSES = %w[draft active retired].freeze

  has_many :financial_statement_sections, dependent: :restrict_with_exception
  has_many :financial_statement_assignments, dependent: :restrict_with_exception

  attr_accessor :publishing

  validates :tenant_id, :name, :version, :effective_from, :status, presence: true
  validates :version, uniqueness: { scope: :tenant_id }
  validates :status, inclusion: { in: STATUSES }
  validate :effective_dates_are_ordered
  validate :published_version_is_immutable, on: :update
  before_destroy :ensure_draft_for_destroy

  scope :for_tenant, ->(tenant_id) { where(tenant_id: tenant_id) }
  scope :effective_on, lambda { |date|
    where.not(status: "draft").where("effective_from <= ?", date)
      .where("effective_to IS NULL OR effective_to >= ?", date)
  }

  def self.resolve!(tenant_id:, on:)
    for_tenant(tenant_id).effective_on(on).order(effective_from: :desc, version: :desc).first!
  end

  private

  def effective_dates_are_ordered
    return if effective_to.blank? || effective_from.blank? || effective_to >= effective_from

    errors.add(:effective_to, "must be on or after the effective-from date")
  end

  def published_version_is_immutable
    if status_in_database == "draft"
      if status != "draft" && !publishing
        errors.add(:base, "publish statement versions through the activation service")
      end
      return
    end

    allowed = publishing && status_in_database == "active" && status == "retired" &&
      (changes.keys - %w[status effective_to updated_at]).empty?
    errors.add(:base, "published statement versions are immutable; clone a draft") unless allowed
  end

  def ensure_draft_for_destroy
    return if status == "draft"

    errors.add(:base, "published statement versions cannot be deleted")
    throw :abort
  end
end
