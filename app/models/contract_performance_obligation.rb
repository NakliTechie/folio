# frozen_string_literal: true

class ContractPerformanceObligation < ApplicationRecord
  SATISFACTIONS = %w[point_in_time over_time].freeze
  SSP_METHODS = %w[observable adjusted_market residual cost_plus].freeze
  PROGRESS_MEASURES = %w[time_elapsed output input].freeze

  belongs_to :contract
  has_many :contract_milestones, dependent: :restrict_with_exception
  has_many :contract_allocation_lines, dependent: :restrict_with_exception
  has_many :contract_schedules, dependent: :restrict_with_exception

  validates :tenant_id, :obligation_no, :description, :satisfaction,
    :standalone_selling_price_minor, :ssp_method, :revenue_account_code, presence: true
  validates :obligation_no, uniqueness: { scope: %i[tenant_id contract_id] },
    numericality: { only_integer: true, greater_than: 0 }
  validates :standalone_selling_price_minor,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :satisfaction, inclusion: { in: SATISFACTIONS }
  validates :ssp_method, inclusion: { in: SSP_METHODS }
  validates :progress_measure, inclusion: { in: PROGRESS_MEASURES }, allow_blank: true
  validate :tenant_matches_contract
  validate :recognition_inputs_are_coherent
  validate :service_dates_are_coherent
  validate :frozen_after_contract_is_signed, on: :update

  scope :in_number_order, -> { order(:obligation_no) }

  def recognition_method
    over_time? ? "straight_line" : "milestone"
  end

  def over_time?
    satisfaction == "over_time"
  end

  private

  def tenant_matches_contract
    errors.add(:contract, "must belong to the same company") if contract && contract.tenant_id != tenant_id
  end

  def recognition_inputs_are_coherent
    if over_time?
      errors.add(:over_time_criterion, "is required for over-time recognition") if over_time_criterion.blank?
      errors.add(:progress_measure, "is required for over-time recognition") if progress_measure.blank?
    elsif over_time_criterion.present? || progress_measure.present?
      errors.add(:base, "point-in-time obligations cannot carry over-time recognition inputs")
    end
  end

  def service_dates_are_coherent
    return unless service_start_date && service_end_date && service_end_date < service_start_date

    errors.add(:service_end_date, "cannot be before the service start date")
  end

  def frozen_after_contract_is_signed
    return unless contract && contract.status != "draft" && has_changes_to_save?

    errors.add(:base, "performance obligations are frozen once the contract is signed")
  end
end
