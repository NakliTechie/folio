# frozen_string_literal: true

class Contract < ApplicationRecord
  SIDES = %w[sell buy mutual internal].freeze
  STATUSES = %w[draft signed active closed].freeze
  TYPES = {
    "service_agreement" => "Service agreement",
    "master_service_agreement" => "Master service agreement",
    "statement_of_work" => "Statement of work",
    "annual_maintenance" => "Annual maintenance contract",
    "order_form" => "Order form"
  }.freeze
  TERM_TYPES = {
    "fixed" => "Fixed term",
    "evergreen" => "Evergreen",
    "auto_renew" => "Auto-renewing",
    "perpetual" => "Perpetual",
    "at_will" => "At will"
  }.freeze
  STAMP_STATUSES = {
    "pending" => "Evidence pending",
    "stamped" => "Stamped",
    "under_stamped" => "Potentially under-stamped",
    "not_applicable" => "Marked not applicable"
  }.freeze
  SIGNATURE_STATUSES = {
    "unsigned" => "Unsigned",
    "partially_signed" => "Partially signed",
    "signed" => "Signed by all parties"
  }.freeze
  REGISTRATION_STATUSES = {
    "not_required" => "Marked not required",
    "pending" => "Registration pending",
    "registered" => "Registered",
    "overdue" => "Registration overdue"
  }.freeze

  belongs_to :entity
  belongs_to :office
  belongs_to :party
  belongs_to :created_domain_event, class_name: "DomainEvent"
  has_many :contract_performance_obligations, dependent: :restrict_with_exception
  has_many :contract_milestones, dependent: :restrict_with_exception
  has_many :contract_allocation_runs, dependent: :restrict_with_exception
  has_many :contract_schedules, dependent: :restrict_with_exception
  has_many :contract_posting_runs, dependent: :restrict_with_exception

  normalizes :contract_number, with: ->(value) { value.to_s.strip.upcase }
  normalizes :currency, :jurisdiction, with: ->(value) { value.to_s.strip.upcase }
  normalizes :place_of_supply_state_code, with: ->(value) { value.to_s.strip.presence }

  validates :tenant_id, :contract_number, :fiscal_year, :title, :side, :contract_type,
    :status, :term_type, :currency, :total_contract_value_minor, :accounting_treatment,
    :jurisdiction, :stamp_status, :signature_status, :registration_status, presence: true
  validates :contract_number, uniqueness: { scope: :tenant_id }
  validates :side, inclusion: { in: SIDES }
  validates :status, inclusion: { in: STATUSES }
  validates :contract_type, inclusion: { in: TYPES.keys }
  validates :term_type, inclusion: { in: TERM_TYPES.keys }
  validates :stamp_status, inclusion: { in: STAMP_STATUSES.keys }
  validates :signature_status, inclusion: { in: SIGNATURE_STATUSES.keys }
  validates :registration_status, inclusion: { in: REGISTRATION_STATUSES.keys }
  validates :gst_treatment, inclusion: { in: %w[domestic_b2b export_lut sez] }
  validates :tds_section,
    inclusion: { in: ->(_) { Taxes::India::Tds::Schedule::SECTIONS.keys } }, allow_blank: true
  validates :currency, length: { is: 3 }
  validates :total_contract_value_minor,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :renewal_notice_days,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :stamp_amount_minor,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :tenant_scopes_match
  validate :sell_side_uses_customer
  validate :dates_are_coherent
  validate :india_state_codes_are_valid
  validate :registration_evidence_is_coherent
  validate :stamp_timing_is_visible

  before_validation :derive_notice_deadline

  scope :in_number_order, -> { order(fiscal_year: :desc, contract_number: :desc) }

  def compliance_flags
    flags = []
    flags << "Stamp evidence pending" if stamp_status == "pending"
    flags << "Potentially under-stamped" if stamp_status == "under_stamped"
    flags << "Stamp date follows execution date" if stamp_date && execution_date && stamp_date > execution_date
    flags << "Signature incomplete" unless signature_status == "signed"
    flags << "Registration overdue" if registration_required? && registration_status == "overdue"
    flags
  end

  private

  def derive_notice_deadline
    self.notice_deadline_date = if end_date && renewal_notice_days
      end_date - renewal_notice_days.days
    end
  end

  def tenant_scopes_match
    errors.add(:entity, "must belong to the contract company") if entity && entity.tenant_id != tenant_id
    errors.add(:office, "must belong to the contract company") if office && office.tenant_id != tenant_id
    errors.add(:party, "must belong to the contract company") if party && party.tenant_id != tenant_id
    if office && entity && office.entity_id != entity_id
      errors.add(:office, "must belong to the selected entity")
    end
  end

  def sell_side_uses_customer
    return unless side == "sell" && party
    return if party.role_codes.include?("customer")

    errors.add(:party, "must have the customer role for a sell-side contract")
  end

  def dates_are_coherent
    if effective_date && end_date && end_date < effective_date
      errors.add(:end_date, "cannot be before the effective date")
    end
    if enforceable_period_end && effective_date && enforceable_period_end < effective_date
      errors.add(:enforceable_period_end, "cannot be before the effective date")
    end
  end

  def india_state_codes_are_valid
    return unless jurisdiction == "IN"

    %i[stamp_state_code place_of_supply_state_code].each do |attribute|
      value = public_send(attribute)
      next if value.blank? || Taxes::India::StateCodes.valid?(value)

      errors.add(attribute, "must be a valid GST state code")
    end
  end

  def registration_evidence_is_coherent
    if registration_required? && registration_status == "not_required"
      errors.add(:registration_status, "cannot be not required when registration is required")
    end
    if !registration_required? && registration_status != "not_required"
      errors.add(:registration_status, "must be not required unless registration is required")
    end
    if registration_status == "registered" && registration_reference.blank?
      errors.add(:registration_reference, "is required for a registered contract")
    end
  end

  def stamp_timing_is_visible
    return unless stamp_status == "stamped" && stamp_date.blank?

    errors.add(:stamp_date, "is required when the contract is marked stamped")
  end
end
