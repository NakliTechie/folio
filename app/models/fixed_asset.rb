# frozen_string_literal: true

class FixedAsset < ApplicationRecord
  STATUSES = %w[draft active retired].freeze

  belongs_to :entity
  belongs_to :office
  belongs_to :asset_class
  belongs_to :created_by, class_name: "User"
  belongs_to :created_domain_event, class_name: "DomainEvent"
  has_many :asset_valuation_terms, dependent: :restrict_with_exception
  has_many :asset_valuations, dependent: :restrict_with_exception
  has_many :asset_transactions, dependent: :restrict_with_exception

  normalizes :asset_number, :component_number, :unit_of_measure,
    with: ->(value) { value.to_s.strip.upcase }

  validates :tenant_id, :asset_number, :component_number, :name, :status,
    :capitalization_date, :quantity, :unit_of_measure, presence: true
  validates :asset_number, uniqueness: { scope: %i[tenant_id component_number] }
  validates :status, inclusion: { in: STATUSES }
  validates :quantity, numericality: { greater_than: 0 }
  validate :scope_matches
  validate :governed_master_stays_stable, on: :update
  validate :retirement_is_coherent

  scope :in_identity_order, -> { order(:asset_number, :component_number) }

  def identity
    "#{asset_number}-#{component_number}"
  end

  private

  def scope_matches
    records = [ entity, office, asset_class, created_domain_event ]
    errors.add(:base, "fixed asset must stay within one company") unless
      records.all? { |record| record&.tenant_id == tenant_id } &&
        office&.entity_id == entity_id && created_by&.memberships&.exists?(tenant_id: tenant_id)
  end

  def governed_master_stays_stable
    return unless asset_transactions.exists?

    stable = %w[tenant_id entity_id office_id asset_class_id asset_number component_number capitalization_date]
    errors.add(:base, "posted asset identity and account determination cannot change") if
      stable.any? { |attribute| will_save_change_to_attribute?(attribute) }
  end

  def retirement_is_coherent
    if status == "retired" && retired_on.blank?
      errors.add(:retired_on, "is required for a retired asset")
    elsif status != "retired" && retired_on.present?
      errors.add(:retired_on, "is only allowed for a retired asset")
    end
    return unless status_in_database == "retired"

    if will_save_change_to_status? || will_save_change_to_retired_on?
      errors.add(:base, "asset retirement is immutable")
    end
  end
end
